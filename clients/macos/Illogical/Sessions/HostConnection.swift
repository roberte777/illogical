//  HostConnection.swift
//  One machine: its control connection, its sessions, its terminals.
//
//  A window can hold several of these at once — the local daemon and any
//  number of remote ones — which is why nothing below is a singleton and why
//  terminals are addressed by `TerminalRef` rather than by id. Two machines
//  both have a terminal 1.
//
//  The control connection is separate from the per-terminal connections. It
//  carries list/create/kill only; terminal traffic never touches it. Over SSH
//  that means a window showing four splits on a remote host holds five
//  connections to it — one control and four terminals — which is what the
//  `ControlMaster` multiplexing in Transport.swift is for.

import Foundation
import IllogicalProtocol
import Observation

/// Identifies a terminal. A bare `UInt64` is not enough once a window can see
/// more than one machine.
struct TerminalRef: Hashable, Sendable {
    var host: ServerHost
    var terminal: UInt64
}

/// Identifies a session, for the same reason.
struct SessionRef: Hashable, Sendable {
    var host: ServerHost
    var session: UInt64
}

@MainActor
@Observable
final class HostConnection: Identifiable {
    /// The host is its own identity: two `.ssh` entries for one destination
    /// are one machine, and there is no id to keep in step with anything.
    nonisolated let host: ServerHost
    /// `nonisolated` because `Identifiable` is not main-actor-isolated and
    /// SwiftUI reads it from wherever it likes. Safe: it is an immutable
    /// `Sendable` value fixed at init.
    nonisolated var id: ServerHost { host }

    enum Status: Equatable {
        case connecting
        case connected
        /// Nothing is coming; the message is `ssh`'s own where there is one.
        case failed(String)
    }

    private(set) var status: Status = .connecting
    var sessions: [SessionSummary] = []
    var terminals: [TerminalSummary] = []

    /// Live controllers, one per open terminal on this host.
    private(set) var controllers: [UInt64: TerminalController] = [:]

    private var control: Connection?
    private var pump: Task<Void, Never>?

    // -- events, for the store that owns the layout --------------------------
    //
    // The host knows what exists; the window knows where it is drawn. Keeping
    // that split is what lets the reconcile stay in one place across every
    // host rather than once per connection.

    /// The session/terminal list changed.
    var onListChanged: (() -> Void)?
    /// The server made a terminal, in reply to our `create`.
    var onCreated: ((UInt64) -> Void)?
    /// `status` changed.
    var onStatusChanged: (() -> Void)?

    init(host: ServerHost) {
        self.host = host
    }

    var displayName: String { host.displayName }

    func terminal(_ id: UInt64) -> TerminalSummary? {
        terminals.first { $0.id == id }
    }

    func ref(_ id: UInt64) -> TerminalRef { TerminalRef(host: host, terminal: id) }

    // MARK: - Control connection

    func connect() {
        disconnect()
        setStatus(.connecting)
        Trace.log("connecting to \(host.displayName)")
        do {
            let connection = try Connection(host: host)
            control = connection
            connection.start()
            try connection.send(.hello, json: HelloBody(client: "Illogical.app"))
            setStatus(.connected)

            pump = Task { [weak self] in
                for await frame in connection.frames {
                    guard let self else { return }
                    await self.handle(frame)
                }
                await self?.controlClosed(connection)
            }
            refresh()
            Trace.log("control connection to \(host.displayName) up")
        } catch {
            Trace.log("connect to \(host.displayName) failed: \(error)")
            setStatus(.failed(describe(error)))
        }
    }

    func disconnect() {
        pump?.cancel()
        pump = nil
        control?.close()
        control = nil
        for id in controllers.keys { closeController(id) }
    }

    func refresh() {
        try? control?.send(.list)
    }

    func createTerminal(sessionName: String) {
        try? control?.send(
            .create, json: CreateBody(sessionName: sessionName, cols: 120, rows: 40))
    }

    func kill(_ id: UInt64) {
        try? control?.send(.kill, terminal: id)
        closeController(id)
    }

    /// A message worth putting in front of somebody.
    ///
    /// For a remote host that is `ssh`'s own complaint where there is one:
    /// "could not resolve hostname" is the answer, and "connection closed" is
    /// not.
    private func describe(_ error: Error) -> String {
        if case .local(let path) = host {
            return "No illogicald at \(path). Start one with `illogicald`."
        }
        return "\(error)"
    }

    private func setStatus(_ next: Status) {
        guard status != next else { return }
        status = next
        onStatusChanged?()
    }

    private func controlClosed(_ connection: Connection) {
        // A connection replaced by a newer one still finishes its stream; only
        // the current one's closing means anything.
        guard control === connection else { return }
        let detail = connection.failureDescription
        control = nil
        sessions = []
        terminals = []
        setStatus(.failed(detail ?? "disconnected"))
        onListChanged?()
    }

    private func handle(_ frame: Frame) {
        switch frame.type {
        case .sessionList:
            guard let list = try? JSONDecoder().decode(SessionListBody.self, from: frame.payload)
            else {
                Trace.log(
                    "bad session list from \(host.displayName): "
                        + (String(data: frame.payload, encoding: .utf8) ?? "<binary>"))
                return
            }
            sessions = list.sessions.map {
                SessionSummary(id: $0.id, name: $0.name, terminals: $0.terminals)
            }
            terminals = list.terminals.map {
                TerminalSummary(
                    id: $0.id,
                    session: $0.session,
                    name: $0.name,
                    command: $0.command,
                    cwd: $0.cwd,
                    cols: $0.cols,
                    rows: $0.rows,
                    residency: Residency(rawValue: $0.residency) ?? .live,
                    attached: $0.attached,
                    ptyReadIdleNanoseconds: $0.ptyReadIdleNanoseconds,
                    exitCode: $0.exitCode)
            }
            setStatus(.connected)
            onListChanged?()

        case .created:
            guard let created = try? JSONDecoder().decode(CreatedBody.self, from: frame.payload)
            else { return }
            onCreated?(created.terminal)
            refresh()

        case .sessionsChanged:
            refresh()

        default:
            break
        }
    }

    // MARK: - Per-terminal connections

    /// The controller for a terminal on this host, creating and attaching one
    /// if needed.
    func controller(for id: UInt64, cols: UInt16, rows: UInt16) -> TerminalController? {
        if let existing = controllers[id] { return existing }
        guard
            let controller = try? TerminalController(
                terminalID: id, host: host, cols: cols, rows: rows)
        else { return nil }
        controller.connect(cols: cols, rows: rows)
        controllers[id] = controller
        return controller
    }

    func closeController(_ id: UInt64) {
        controllers[id]?.disconnect()
        controllers[id] = nil
    }

    /// Drop controllers for terminals the server no longer lists, so their
    /// reader threads do not linger on a dead socket.
    func pruneControllers() {
        let live = Set(terminals.map(\.id))
        for id in controllers.keys where !live.contains(id) {
            closeController(id)
        }
    }
}
