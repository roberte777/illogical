//  TerminalController.swift
//  Wires one connection to one terminal engine.
//
//  One connection per terminal, per docs/PROTOCOL.md. The attach sequence is:
//
//      attach -> snapshot_begin -> snapshot_chunk... -> snapshot_ready
//                                                    -> PAINT
//             -> output / snapshot_chunk (history) interleaved
//             -> snapshot_end
//
//  Output frames are applied on the connection's reader thread, straight into
//  the engine, so a busy terminal never queues work onto the main thread.

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
    /// Scrollback rows restored so far, for the UI to show progress.
    private(set) var restoredHistoryRows = 0

    let engine: TerminalEngine
    private var connection: Connection?
    private var pump: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?

    /// Accumulates the GHOSTSNP stream. Decoding is buffered for now; the
    /// streaming decoder (a GhosttyReader callback) is the M3 refinement.
    private var snapshotBuffer = Data()

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
        historyTask?.cancel()
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
            snapshotBuffer.removeAll(keepingCapacity: true)
            snapshotBytes = 0

        case .snapshotChunk:
            snapshotBuffer.append(frame.payload)
            snapshotBytes += frame.payload.count

        case .snapshotReady:
            applySnapshot()

        case .snapshotEnd:
            snapshotBuffer.removeAll(keepingCapacity: false)
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

    private func applySnapshot() {
        readyAt = Date()
        if let attachSentAt {
            Signposts.milestone(
                "snapshot-ready", seconds: Signposts.sinceLaunch(),
                detail:
                    "terminal=\(terminalID) since-attach=\(Self.ms(Date().timeIntervalSince(attachSentAt))) bytes=\(snapshotBytes)"
            )
        }
        guard !snapshotBuffer.isEmpty else {
            state = .live
            return
        }
        do {
            let restore = try SnapshotRestore(snapshot: snapshotBuffer)
            let terminal = try restore.ready()
            engine.adopt(terminal: terminal, cols: engine.cols, rows: engine.rows)
            // We can paint now. Everything below is scrollback catching up.
            state = .live
            // Split out from `ready -> first frame` on purpose: if that total
            // moves with scrollback size, this is where it moved. Today it
            // does, because `SnapshotRestore` copies the whole GHOSTSNP
            // stream before decoding any of it — the streaming decoder is
            // still outstanding from M2.
            Signposts.milestone(
                "snapshot-decoded", seconds: Signposts.sinceLaunch(),
                detail:
                    "terminal=\(terminalID) since-ready=\(Self.ms(Date().timeIntervalSince(readyAt ?? Date()))) bytes=\(snapshotBytes)"
            )

            restoreHistory(restore)
        } catch {
            // A snapshot we cannot decode is not fatal: live output still
            // renders, we just start from a blank screen.
            state = .live
        }
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
    private func restoreHistory(_ restore: SnapshotRestore) {
        let engine = self.engine
        let terminalID = self.terminalID
        historyTask?.cancel()
        historyTask = Task.detached(priority: .utility) { [weak self] in
            var pages = 0
            while !Task.isCancelled {
                let more = (try? engine.withLock { try restore.restoreNextHistoryPage() }) ?? false
                guard more else { break }
                pages += 1
                // A well-formed snapshot terminates on its own; the bound is
                // only so a corrupt one cannot spin forever.
                if pages > 4096 { break }
            }
            let restored = pages
            await MainActor.run {
                self?.restoredHistoryRows = restored
                Signposts.milestone(
                    "history-restored", seconds: Signposts.sinceLaunch(),
                    detail: "terminal=\(terminalID) pages=\(restored)")
            }
        }
    }

    private func connectionClosed() {
        if case .exited = state { return }
        if case .failed = state { return }
        state = .failed("disconnected")
    }
}
