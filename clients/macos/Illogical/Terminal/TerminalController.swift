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

    /// Accumulates the GHOSTSNP stream. Decoding is buffered for now; the
    /// streaming decoder (a GhosttyReader callback) is the M3 refinement.
    private var snapshotBuffer = Data()

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

        case .snapshotChunk:
            snapshotBuffer.append(frame.payload)

        case .snapshotReady:
            applySnapshot()

        case .snapshotEnd:
            snapshotBuffer.removeAll(keepingCapacity: false)

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

    private func applySnapshot() {
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

            var pages = 0
            while try restore.restoreNextHistoryPage() {
                pages += 1
                if pages > 4096 { break }
            }
            restoredHistoryRows = pages
        } catch {
            // A snapshot we cannot decode is not fatal: live output still
            // renders, we just start from a blank screen.
            state = .live
        }
    }

    private func connectionClosed() {
        if case .exited = state { return }
        if case .failed = state { return }
        state = .failed("disconnected")
    }
}
