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
        case exited(Int32)
        case failed(String)
    }

    let terminalID: UInt64
    private(set) var state: State = .connecting

    // No `scrollbackRows` here. There was one, written once when the restore
    // finished and read by nothing, and it could not have been the mechanism
    // for a loading state even in principle: it is a final total, available
    // only after the last thing anybody would want to draw a loading state
    // for. What the scrollbar draws instead is the count the *engine* holds,
    // declared at READY and counted down as pages land.

    let engine: TerminalEngine
    private var connection: Connection?
    private var pump: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyToken: HistoryToken?

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

    init(terminalID: UInt64, cols: UInt16, rows: UInt16) throws {
        self.terminalID = terminalID
        self.engine = try TerminalEngine(cols: cols, rows: rows)
    }

    // No deinit teardown: `pump` and `connection` are main-actor state and
    // deinit is nonisolated. Callers use `disconnect()`, which SessionStore
    // does when a terminal closes.

    func connect(socketPath: String, cols: UInt16, rows: UInt16) {
        do {
            let connection = try Connection(socketPath: socketPath)
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
                    await self.handle(frame)
                }
                await self?.connectionClosed()
            }
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
        engine.resize(cols: cols, rows: rows, cellWidth: 0, cellHeight: 0)
        guard let connection else { return }
        try? connection.send(
            .resize, terminal: terminalID, json: ResizeBody(cols: cols, rows: rows))
    }

    func disconnect() {
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

    // MARK: - Frames

    private func handle(_ frame: Frame) {
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
            let message =
                (try? JSONDecoder().decode(ErrBody.self, from: frame.payload))?.message
                ?? "server error"
            state = .failed(message)

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
            state = .live
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
            state = .live
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
            state = .live
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

    private func connectionClosed() {
        // Whatever the pipe still holds is a snapshot that will never be
        // completed, and it may be a session's whole scrollback.
        stopHistoryRestore()
        restore?.stream.abandon()
        restore = nil
        // Nothing is coming down a closed connection. The screen stays as it
        // is, so the bar has to stop claiming there is more above it.
        engine.clearPendingHistory()
        if case .exited = state { return }
        if case .failed = state { return }
        state = .failed("disconnected")
    }
}
