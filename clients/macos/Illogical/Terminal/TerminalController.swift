//  TerminalController.swift
//  Wires one connection to one terminal engine.
//
//  One connection per terminal, per docs/PROTOCOL.md. The attach sequence is:
//
//      attach -> snapshot_begin -> snapshot_chunk... -> snapshot_ready
//                                                    -> PAINT
//             -> snapshot_chunk (history)... -> snapshot_end
//                                            -> RESTORE SCROLLBACK
//             -> output
//
//  History is not interleaved with output, and the decode of it does not begin
//  until `snapshot_end`. Both are properties of the current implementation
//  rather than of the protocol, and both are explained where they are caused:
//  the server encodes under the terminal lock (src/daemon/Terminal.zig), and
//  `restoreHistory` below says why it waits.
//
//  `Connection` reads frames on its own thread, but they are delivered through
//  an AsyncStream consumed on the main actor, so every case in `handle` runs
//  there -- including `output`, which writes straight into the engine.

import Foundation
import GhosttyVt
import IllogicalProtocol
import OSLog

@MainActor
@Observable
final class TerminalController {
    enum State: Equatable {
        case connecting
        case attaching
        case live
        /// The connection went away and is being made again. The screen
        /// underneath stays: the last thing the terminal showed is still the
        /// best guess at what it shows, and throwing it away would make a
        /// dropped wifi packet look like a crash.
        case reconnecting(attempt: Int)
        case exited(Int32)
        case failed(String)

        var isReconnecting: Bool {
            if case .reconnecting = self { return true }
            return false
        }
    }

    let terminalID: UInt64
    /// The machine this terminal's PTY is on. Held rather than passed in,
    /// because the connection may have to be made more than once and nothing
    /// above here should have to remember where a terminal was.
    let host: ServerHost
    private(set) var state: State = .connecting

    // No `scrollbackRows` here. There was one, written once when the restore
    // finished and read by nothing, and it could not have been the mechanism
    // for a loading state even in principle: it is a final total, available
    // only after the last thing anybody would want to draw a loading state
    // for. What the scrollbar draws instead is the count the *engine* holds,
    // declared at READY and counted down as pages land.

    let engine: TerminalEngine

    /// The find bar over this terminal, and the loop that drives its search.
    ///
    /// Here rather than on the pane because a search is bound to the terminal's
    /// own screens: two views of one terminal are two views of one search, and
    /// a pane moving in the split tree must not restart it.
    let search: SearchSession

    private var connection: Connection?
    private var pump: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyToken: HistoryToken?

    /// The grid the surface last asked for, so a reconnect attaches at the
    /// size the window is now rather than the size it was when it opened.
    private var cols: UInt16
    private var rows: UInt16
    /// The retry in flight, and how far into the backoff we are.
    private var retry: Task<Void, Never>?
    private var backoff = Backoff()
    /// Set by `disconnect()`. A connection that closed because we closed it is
    /// not something to recover from.
    private var closedByUs = false

    /// The attach in flight: the GHOSTSNP byte pipe and the decoder pulling
    /// from it, live from `snapshot_begin` until history has been restored.
    /// Nothing accumulates a copy of the stream — chunks go into the pipe and
    /// are released as the decoder reads them.
    private var restore: SnapshotRestore?
    /// Set once `ready()` has produced a terminal the engine adopted, so
    /// `snapshot_end` knows there is a decode to carry on with.
    private var readyDecoded = false

    /// The attach timeline, for the launch budget. `ready` to first frame is
    /// the number docs/CLIENT.md says must not vary with scrollback size: if
    /// it does, something is buffering that should be streaming.
    private var attachSentAt: Date?
    private var readyAt: Date?
    private var didReportFirstFrame = false
    private var attachInterval: OSSignpostIntervalState?
    private var snapshotBytes = 0

    init(terminalID: UInt64, host: ServerHost, cols: UInt16, rows: UInt16) throws {
        self.terminalID = terminalID
        self.host = host
        self.cols = cols
        self.rows = rows
        let engine = try TerminalEngine(cols: cols, rows: rows)
        self.engine = engine
        self.search = SearchSession(engine: engine)
    }

    // No deinit teardown: `pump` and `connection` are main-actor state and
    // deinit is nonisolated. Callers use `disconnect()`, which SessionStore
    // does when a terminal closes.

    /// Open a connection to this terminal's host and attach.
    ///
    /// Which machine that is does not appear below this line: a remote host is
    /// `ssh <dest> illogicald --stdio` and the frames on it are the same ones.
    func connect(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
        openConnection()
    }

    private func openConnection() {
        // Whatever was there is not coming back; a second pump over a dead
        // stream would report a close we already handled.
        pump?.cancel()
        pump = nil
        connection?.close()
        connection = nil

        // A new connection voids whatever the old one was streaming, so the
        // pipe goes back now rather than whenever the next `snapshot_begin`
        // gets round to it. `connectionClosed` cannot be relied on for this:
        // its identity guard is what stops a replaced pump tearing down its
        // successor, so on the Retry path the old pump's tail returns early
        // and, if the `Connection(host:)` below throws, nothing else ever
        // frees a half-delivered snapshot that may hold a whole session's
        // scrollback.
        stopHistoryRestore()
        restore?.stream.abandon()
        restore = nil
        engine.clearPendingHistory()

        do {
            let connection = try Connection(host: host)
            self.connection = connection
            connection.start()

            try connection.send(.hello, json: HelloBody(client: "Illogical.app"))
            try connection.send(
                .attach, terminal: terminalID, json: AttachBody(cols: cols, rows: rows))
            state = .attaching
            attachSentAt = Date()
            attachInterval = Signposts.attach.beginInterval("attach")
            Signposts.milestone(
                "attach-sent", seconds: Signposts.sinceLaunch(),
                detail: "terminal=\(terminalID)")

            pump = Task { [weak self] in
                for await frame in connection.frames {
                    guard let self else { return }
                    await self.handle(frame, from: connection)
                }
                await self?.connectionClosed(connection)
            }
        } catch {
            // Not fatal, and not different from the connection dying a moment
            // later: a host that is not there yet is a host to try again.
            Trace.log("terminal \(terminalID): connect failed: \(error)")
            scheduleReconnect()
        }
    }

    /// Ask for the whole terminal again, on the connection we already have.
    ///
    /// This is the recovery path for every kind of desync, and the server asks
    /// for it by name when a client falls behind its output queue: it has
    /// already unsubscribed us, so nothing more is coming until we attach
    /// again. Attach is O(screen), which is what makes throwing the state away
    /// and starting over the cheap option rather than the drastic one — see
    /// docs/PROTOCOL.md, "Desync".
    ///
    /// `snapshot_begin` does the tearing down. It stops the history restore,
    /// abandons the half-delivered snapshot and clears the pending region,
    /// because a second snapshot arriving on one connection is exactly this.
    private func reattach() {
        guard let connection else { return }
        state = .attaching
        attachSentAt = Date()
        Signposts.milestone(
            "reattach-sent", seconds: Signposts.sinceLaunch(),
            detail: "terminal=\(terminalID) reason=desync")
        do {
            try connection.send(
                .attach, terminal: terminalID,
                json: AttachBody(cols: engine.cols, rows: engine.rows))
        } catch {
            state = .failed("\(error)")
        }
    }

    func send(_ bytes: [UInt8]) {
        guard let connection else { return }
        try? connection.send(.input, terminal: terminalID, payload: Data(bytes))
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard cols > 0, rows > 0 else { return }
        // Remembered even while disconnected, so a window resized during an
        // outage reattaches at the size it is now rather than the size it was.
        self.cols = cols
        self.rows = rows
        engine.resize(cols: cols, rows: rows, cellWidth: 0, cellHeight: 0)
        guard let connection else { return }
        try? connection.send(
            .resize, terminal: terminalID, json: ResizeBody(cols: cols, rows: rows))
    }

    func disconnect() {
        closedByUs = true
        // Nothing is going to search a terminal that is going away, and the
        // pump is a timer: left running it would keep waking the main actor for
        // a pane that is no longer on screen.
        search.close()
        retry?.cancel()
        retry = nil
        stopHistoryRestore()
        // A half-delivered snapshot is worth nothing now, and the pipe may be
        // holding a whole session's scrollback.
        restore?.stream.abandon()
        restore = nil
        // History that will never arrive is not pending, it is gone.
        engine.clearPendingHistory()
        pump?.cancel()
        connection?.close()
        connection = nil
    }

    /// Try again now, rather than when the backoff says to. What the pane's
    /// "Retry" button does.
    func retryNow() {
        guard !closedByUs else { return }
        retry?.cancel()
        retry = nil
        backoff.reset()
        openConnection()
    }

    // MARK: - Reconnecting
    //
    // A connection that goes away is a client that has missed output, and the
    // protocol already has a recovery for that: throw the terminal state away
    // and replay the attach handshake. So there is nothing here but *when* —
    // `openConnection` sends the same `attach` it sends the first time, and
    // `snapshot_begin` does the tearing down, exactly as it does for a desync.
    // See docs/PROTOCOL.md, "Desync".

    private func scheduleReconnect() {
        guard !closedByUs, retry == nil else { return }
        // An exited child is not a lost connection. Nothing is coming back.
        if case .exited = state { return }

        let delay = backoff.next()
        state = .reconnecting(attempt: backoff.attempt)
        Trace.log(
            "terminal \(terminalID) on \(host.displayName): reconnecting in "
                + String(format: "%.2fs", delay) + " (attempt \(backoff.attempt))")

        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retry = nil
            guard !self.closedByUs else { return }
            self.openConnection()
        }
    }

    // MARK: - Frames

    /// Feed a frame as though it had arrived on `source`. For tests: the frame
    /// the guard below exists for is one buffered on a *superseded*
    /// connection, and arranging for a real one to be delivered after the swap
    /// is a race a test cannot reliably win -- the pump and `openConnection`
    /// are on the same actor, so which of them runs first is up to the
    /// scheduler.
    func handleForTesting(_ frame: Frame, from source: Connection) {
        handle(frame, from: source)
    }

    /// Takes the connection the frame arrived on, for the same reason
    /// `connectionClosed` does — and it is the same hazard one frame earlier.
    /// `close()` finishes the stream, but frames already buffered in it are
    /// still delivered, so a pane that reattaches while the old connection had
    /// an `exited` or an `err` in flight applies it to the new one: the
    /// terminal is alive on the server and running, and the pane is
    /// permanently dead with no retry, because `scheduleReconnect` refuses to
    /// act on `.exited`. Output and snapshot chunks are worse still -- they
    /// are another terminal's screen written into this one.
    private func handle(_ frame: Frame, from source: Connection) {
        guard connection === source else { return }
        switch frame.type {
        case .welcome:
            break

        case .snapshotBegin:
            beginSnapshot()

        case .snapshotChunk:
            restore?.stream.append(frame.payload)
            snapshotBytes += frame.payload.count

        case .snapshotReady:
            applySnapshot()

        case .snapshotEnd:
            endSnapshot()
            if let attachSentAt {
                Signposts.milestone(
                    "snapshot-end", seconds: Signposts.sinceLaunch(),
                    detail:
                        "terminal=\(terminalID) since-attach=\(Self.ms(Date().timeIntervalSince(attachSentAt)))"
                )
            }
            if let attachInterval {
                Signposts.attach.endInterval("attach", attachInterval)
                self.attachInterval = nil
            }

        case .output:
            // Straight into our VT engine, unmodified. This is the whole point.
            frame.payload.withUnsafeBytes { engine.write($0) }

        case .exited:
            let code = (try? JSONDecoder().decode(ExitedBody.self, from: frame.payload))?.code ?? 0
            state = .exited(code)

        case .error:
            let body = try? JSONDecoder().decode(ErrBody.self, from: frame.payload)
            if body.map({ ProtocolErrorCode(rawValue: $0.code) == .desync }) ?? false {
                reattach()
                return
            }
            state = .failed(body?.message ?? "server error")

        default:
            break
        }
    }

    /// The first frame this terminal's renderer submitted.
    ///
    /// Reported by the surface with the timestamp taken on the render thread,
    /// so the hop to the main actor is not counted as part of it.
    func didPresentFirstFrame(at moment: Date) {
        guard !didReportFirstFrame else { return }
        didReportFirstFrame = true
        let sinceReady = readyAt.map { moment.timeIntervalSince($0) }
        Signposts.milestone(
            "first-frame", seconds: Signposts.sinceLaunch(moment),
            detail:
                "terminal=\(terminalID) since-ready=\(sinceReady.map(Self.ms) ?? "n/a") snapshot=\(snapshotBytes)B"
        )
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.2fms", seconds * 1000)
    }

    /// Open a pipe for the snapshot the server is about to send.
    private func beginSnapshot() {
        // Before anything can free or replace the terminal a previous restore
        // is decoding into. A second snapshot on one connection is what
        // desync recovery looks like, and nothing upstream forbids it.
        stopHistoryRestore()
        restore?.stream.abandon()
        // Whatever the last snapshot said it owed is now void, and the screen
        // it described is still up until READY replaces it. Clearing here
        // rather than leaving it to `adopt` keeps a stale pending region off
        // that screen in the meantime.
        engine.clearPendingHistory()
        restore = try? SnapshotRestore(stream: SnapshotStream())
        readyDecoded = false
        snapshotBytes = 0
    }

    /// The server has passed the READY marker: everything needed to paint is
    /// in the pipe, and nothing beyond it is waited for.
    private func applySnapshot() {
        readyAt = Date()
        if let attachSentAt {
            Signposts.milestone(
                "snapshot-ready", seconds: Signposts.sinceLaunch(),
                detail:
                    "terminal=\(terminalID) since-attach=\(Self.ms(Date().timeIntervalSince(attachSentAt))) bytes=\(snapshotBytes)"
            )
        }
        guard let restore, snapshotBytes > 0 else {
            becameLive()
            return
        }
        do {
            let terminal = try restore.ready()
            engine.adopt(terminal: terminal, cols: engine.cols, rows: engine.rows)
            // The snapshot knows how much history it is about to send, and
            // says so at READY — before a byte of it has arrived. Declaring it
            // now is what lets the scrollbar be the right size on the first
            // frame and draw the part that has not landed as pending, rather
            // than growing to meet it while the user scrolls. See
            // docs/CLIENT.md, "The loading state".
            engine.declarePendingHistory(rows: restore.declaredHistoryRows)
            // We can paint now. Everything below is scrollback catching up.
            readyDecoded = true
            becameLive()
            // Split out from `ready -> first frame` on purpose: if that total
            // moves with scrollback size, this is where it moved. It should
            // not: the decoder stops at READY, and the bytes past it are still
            // arriving.
            Signposts.milestone(
                "snapshot-decoded", seconds: Signposts.sinceLaunch(),
                detail:
                    "terminal=\(terminalID) since-ready=\(Self.ms(Date().timeIntervalSince(readyAt ?? Date()))) bytes=\(snapshotBytes)"
            )
        } catch {
            // A snapshot we cannot decode is not fatal: live output still
            // renders, we just start from a blank screen.
            self.restore?.stream.abandon()
            self.restore = nil
            engine.clearPendingHistory()
            becameLive()
        }
    }

    /// The last history byte has arrived. Close the pipe and start prepending.
    private func endSnapshot() {
        guard let restore else { return }
        restore.stream.close()
        guard readyDecoded else {
            self.restore = nil
            return
        }
        restoreHistory(restore)
    }

    /// Whether a history restore may still touch its terminal.
    ///
    /// `Task.cancel()` is not enough on its own. A cancelled task blocked on
    /// the engine's lock still wakes up holding it, and by then `adopt` may
    /// have freed the terminal the decoder borrows — `snapshot.h` is explicit
    /// that the terminal must outlive the decoder. Flipping this flag *under
    /// the same lock* the decode happens under is what closes that window:
    /// the task cannot be between the check and the call.
    private final class HistoryToken: @unchecked Sendable {
        var isCancelled = false
    }

    /// Stop any history restore from touching the current terminal again.
    ///
    /// Must be called before anything frees or replaces that terminal.
    private func stopHistoryRestore() {
        if let historyToken {
            engine.withLock { historyToken.isCancelled = true }
            self.historyToken = nil
        }
        historyTask?.cancel()
        historyTask = nil
    }

    /// Prepend the snapshot's scrollback, newest first, behind the frame the
    /// user is already looking at.
    ///
    /// Off the main actor and at a lower priority than the render thread, on
    /// purpose: this used to run inline after `adopt`, which pushed the first
    /// frame back by however long the history took — eight milliseconds at
    /// twenty thousand lines, measurably worse than an empty terminal. G3
    /// says the first frame must not depend on how much scrollback there is,
    /// and G4 says history must not block anything, so it cannot be here.
    ///
    /// Each page is decoded under the engine's lock. The decoder writes into
    /// the terminal the engine now owns and the render thread reads that same
    /// terminal, so this is a mutation the engine did not make and cannot
    /// know about. Per page rather than around the whole loop, so frames keep
    /// coming out while a large history restores.
    ///
    /// Started at `snapshot_end`, not at READY, and that is deliberate: the
    /// decoder reads inside `next()`, under this lock, and `SnapshotStream`
    /// cannot block a starved read without stalling the renderer for as long
    /// as the transport takes. Once the last chunk has landed every remaining
    /// byte is in the pipe, so no read here can come up short. Decoding pages
    /// as they arrive means solving that first; see docs/CLIENT.md.
    private func restoreHistory(_ restore: SnapshotRestore) {
        // Never spawn over a live restore. Assigning `historyToken` below
        // orphans whatever it held, and an orphaned token can never be
        // cancelled -- which is the one thing keeping that task out of a
        // terminal `adopt` has freed. The guard lives here rather than at the
        // call site because it is this assignment that creates the hazard, so
        // every future caller needs it too.
        stopHistoryRestore()

        let engine = self.engine
        let terminalID = self.terminalID
        let token = HistoryToken()
        historyToken = token

        historyTask = Task.detached(priority: .utility) { [weak self] in
            var pages = 0
            while !Task.isCancelled {
                // The cancellation check, the decode and the pending count are
                // one operation under the lock. Outside it, a task that had
                // already passed the check could still call into a decoder
                // whose terminal `adopt` has since freed — and a frame could
                // catch the rows a page added without the matching drop in
                // what is still owed, which is the one thing that would make
                // the knob jump.
                let more = engine.withLock { () -> Bool in
                    guard !token.isCancelled else { return false }
                    // Zero rows is not the end: a page that could not be
                    // applied is still consumed, and history continues.
                    guard let rows = (try? restore.restoreNextHistoryPage()) ?? nil else {
                        return false
                    }
                    engine.historyPageRestoredLocked(rows: rows)
                    return true
                }
                guard more else { break }
                pages += 1
                // A well-formed snapshot terminates on its own; the bound is
                // only so a corrupt one cannot spin forever. Say so rather
                // than quietly showing a shortened history — 4096 pages was
                // reachable at a hundred thousand lines.
                if pages >= 1 << 20 {
                    Trace.log(
                        "terminal \(terminalID): history restore stopped at \(pages) pages")
                    break
                }
            }
            // How many *rows* those pages held, for the log. Outside
            // `withLock`: `scrollbar` takes the same lock itself, and NSLock
            // is not recursive.
            //
            // Net of anything still pending, which is what makes this the
            // rows that arrived rather than the rows the snapshot claimed. A
            // restore that stopped early — the page backstop, a cancelled
            // task — would otherwise log the promise as if it were delivery.
            let bar = engine.scrollbar
            let rows = Int(bar.total - bar.pending) - Int(bar.length)
            let restored = pages
            await MainActor.run {
                // Drop the decoder and whatever the pipe still holds — but only
                // if this task is still the current one. A cancelled task runs
                // its tail anyway, and comparing the restore alone is not
                // enough to tell the two apart when a second `snapshot_end`
                // re-entered `restoreHistory` with the same object: the loser
                // would clear `restore` out from under the live decode, and
                // the next disconnect would then not abandon its pipe.
                //
                // The pending count is dropped under that same guard, and for
                // a sharper reason: it is the *loser* that must not touch it.
                // Clearing it unconditionally here would wipe the count the
                // winning restore is still counting down, and the pending
                // region would vanish while history was still arriving.
                if self?.historyToken === token {
                    self?.restore = nil
                    // Whatever the snapshot declared, this is what it sent.
                    // The extent is advisory, so a snapshot whose pages
                    // applied fewer rows than promised would otherwise leave a
                    // sliver of the bar pending for the terminal's lifetime.
                    self?.engine.clearPendingHistory()
                }
                Trace.log(
                    "terminal \(terminalID): restored \(restored) history pages, "
                        + "\(rows) rows of scrollback")
                Signposts.milestone(
                    "history-restored", seconds: Signposts.sinceLaunch(),
                    detail: "terminal=\(terminalID) pages=\(restored) rows=\(rows)")
            }
        }
    }

    /// The attach finished and the terminal is on screen.
    ///
    /// Also where the backoff is forgiven. On the *attach* rather than on the
    /// connect, because a host whose daemon has died accepts a connection and
    /// drops it: resetting on a socket opening would turn the backoff into a
    /// tight loop against exactly the machine that needs one.
    private func becameLive() {
        state = .live
        backoff.reset()
    }

    /// The stream for `connection` has finished.
    ///
    /// Takes the connection it is speaking for, and ignores anything that is
    /// not the current one. Without that check a *replaced* pump's tail tears
    /// down its successor: a pane sitting in `.failed` with its socket open --
    /// which the server produces by answering `no_such_terminal` and keeping
    /// the connection -- has a live pump, so pressing Retry opens connection B
    /// and then lets A's tail abort B's in-flight snapshot, close it, and
    /// schedule a fresh backoff. Every Retry threw away a just-negotiated
    /// channel. `HostConnection.controlClosed(_:)` has had this guard all
    /// along; this is the same hazard.
    private func connectionClosed(_ closing: Connection) {
        guard connection === closing else { return }
        // Whatever the pipe still holds is a snapshot that will never be
        // completed, and it may be a session's whole scrollback.
        stopHistoryRestore()
        restore?.stream.abandon()
        restore = nil
        // Nothing is coming down a closed connection. The screen stays as it
        // is, so the bar has to stop claiming there is more above it.
        engine.clearPendingHistory()
        if case .exited = state { return }

        // Everything else is worth trying again. A network that went away is
        // not a different kind of failure from a client that fell behind its
        // output queue -- both mean "you have missed something, start over" --
        // and the server keeps the terminal running either way. That is the
        // whole reason this is three lines: `openConnection` sends the same
        // `attach` it sent the first time.
        //
        // The screen is deliberately left alone. It is the last thing the
        // terminal showed and still the best guess at what it shows; blanking
        // it would make a dropped packet look like a crash, and the snapshot
        // that arrives on reconnect replaces it wholesale anyway.
        // Nothing may write to it again. `send` and `resize` both check, and a
        // write to a socket whose peer has gone is an EPIPE at best -- the
        // transport turns off the signal that would otherwise be a SIGPIPE,
        // but there is no reason to reach for it.
        let detail = connection?.failureDescription
        Trace.log(
            "terminal \(terminalID) on \(host.displayName): connection closed"
                + (detail.map { " (\($0))" } ?? ""))
        connection?.close()
        connection = nil
        scheduleReconnect()
    }
}
