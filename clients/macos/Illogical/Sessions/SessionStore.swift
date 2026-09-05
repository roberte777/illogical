//  SessionStore.swift
//  Connection state for a host: its sessions, its terminals, and which one is
//  in front.
//
//  The control connection is separate from the per-terminal connections. It
//  carries list/create/kill only; terminal traffic never touches it.

import AppKit
import Foundation
import IllogicalProtocol
import Observation

@MainActor
@Observable
final class SessionStore {
    var host: ServerHost = .local(socketPath: SessionStore.defaultSocketPath)
    var sessions: [SessionSummary] = []
    var terminals: [TerminalSummary] = []
    var selectedID: TerminalSummary.ID?
    var connectionError: String?
    /// The toolbar lives in a title bar accessory and the menu lives in the
    /// content view, so the open/closed state has to be somewhere both can see.
    ///
    /// ILLOGICAL_OPEN_SESSION_MENU opens it at launch, alongside
    /// ILLOGICAL_TRACE, so it can be screenshotted without driving the mouse.
    var sessionMenuOpen =
        ProcessInfo.processInfo.environment["ILLOGICAL_OPEN_SESSION_MENU"] != nil

    /// Pane layout for the selected tab. Purely client state: the server has no
    /// concept of splits, and each leaf is its own connection to its own PTY.
    var layout: SplitTree = .leaf(0)
    /// Which pane takes keyboard focus and is the target of a split.
    var focusedTerminalID: UInt64?

    /// A split is pending until the server hands back the new terminal's id.
    private var pendingSplit: SplitTree.Axis?

    /// Live controllers, one per open terminal.
    private(set) var controllers: [UInt64: TerminalController] = [:]

    private var control: Connection?
    private var pump: Task<Void, Never>?

    var selected: TerminalSummary? {
        guard let selectedID else { return nil }
        return terminals.first { $0.id == selectedID }
    }

    var focusedTerminal: TerminalSummary? {
        guard let focusedTerminalID else { return nil }
        return terminals.first { $0.id == focusedTerminalID }
    }

    var selectedSession: SessionSummary? {
        guard let selected else { return sessions.first }
        return sessions.first { $0.id == selected.session }
    }

    /// Terminals in the session that is currently in front. These are the tabs.
    var visibleTerminals: [TerminalSummary] {
        guard let session = selectedSession else { return terminals }
        return terminals.filter { $0.session == session.id }
    }

    static var defaultSocketPath: String {
        if let override = ProcessInfo.processInfo.environment["ILLOGICAL_SOCK"] {
            return override
        }
        let state =
            ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/state")
            .path
        return state + "/illogical/server.sock"
    }

    var socketPath: String {
        switch host {
        case .local(let path): path
        case .ssh: SessionStore.defaultSocketPath
        }
    }

    // MARK: - Control connection

    func connect() {
        Trace.log("connecting to \(socketPath)")
        do {
            let connection = try Connection(socketPath: socketPath)
            control = connection
            connection.start()
            try connection.send(.hello, json: HelloBody(client: "Illogical.app"))
            connectionError = nil

            pump = Task { [weak self] in
                for await frame in connection.frames {
                    guard let self else { return }
                    await self.handle(frame)
                }
            }
            refresh()
            Trace.log("control connection up")
        } catch {
            Trace.log("connect failed: \(error)")
            connectionError =
                "No illogicald at \(socketPath). Start one with `illogicald`."
        }
    }

    func refresh() {
        try? control?.send(.list)
    }

    func createTerminal(sessionName: String? = nil) {
        let name = sessionName ?? selectedSession?.name ?? "default"
        try? control?.send(.create, json: CreateBody(sessionName: name, cols: 120, rows: 40))
    }

    func kill(_ id: UInt64) {
        // The server signals the child; the terminal is retired when it
        // actually exits, and we find out from `sessions_changed`.
        try? control?.send(.kill, terminal: id)
        closeController(id)
    }

    private func handle(_ frame: Frame) {
        Trace.log("frame \(frame.type) payload=\(frame.payload.count)")
        switch frame.type {
        case .sessionList:
            guard let list = try? JSONDecoder().decode(SessionListBody.self, from: frame.payload)
            else {
                Trace.log(
                    "bad session list: \(String(data: frame.payload, encoding: .utf8) ?? "<binary>")"
                )
                return
            }
            Trace.log("\(list.sessions.count) sessions, \(list.terminals.count) terminals")
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
            // Tear down connections for terminals the server has retired,
            // otherwise their reader threads linger on a dead socket.
            let live = Set(terminals.map(\.id))
            for id in controllers.keys where !live.contains(id) {
                closeController(id)
            }

            if selectedID == nil || !terminals.contains(where: { $0.id == selectedID }) {
                selectedID = terminals.first?.id
            }
            reconcileLayout()

        case .created:
            guard let created = try? JSONDecoder().decode(CreatedBody.self, from: frame.payload)
            else { return }
            refresh()
            if let axis = pendingSplit, let target = focusedTerminalID {
                // A split keeps the current tab and adds a pane beside it.
                layout = layout.splitting(target, with: created.terminal, axis: axis)
                focusedTerminalID = created.terminal
                pendingSplit = nil
            } else {
                selectedID = created.terminal
            }

        case .sessionsChanged:
            refresh()

        default:
            break
        }
    }

    // MARK: - Splits

    /// Split the focused pane, creating a terminal to fill the new half.
    func split(_ axis: SplitTree.Axis) {
        guard focusedTerminalID != nil else { return }
        pendingSplit = axis
        createTerminal()
    }

    /// Close the focused pane. The last pane closing closes the terminal.
    func closeFocusedPane() {
        guard let focused = focusedTerminalID else { return }
        kill(focused)
    }

    /// Keep the layout in step with the terminals that actually exist. A pane
    /// whose terminal was retired collapses; a newly selected tab resets to a
    /// single pane.
    private func reconcileLayout() {
        guard let selected = selectedID else {
            layout = .leaf(0)
            focusedTerminalID = nil
            return
        }

        let live = Set(terminals.map(\.id))
        var next = layout
        for id in next.terminals where !live.contains(id) {
            next = next.removing(id) ?? .leaf(selected)
        }
        // Switching tabs starts a fresh single-pane layout for that terminal.
        if !next.contains(selected) { next = .leaf(selected) }
        layout = next

        if let focused = focusedTerminalID, layout.contains(focused) { return }
        focusedTerminalID = layout.terminals.first
    }

    // MARK: - Per-terminal connections

    /// The controller for a terminal, creating and attaching one if needed.
    func controller(for id: UInt64, cols: UInt16, rows: UInt16) -> TerminalController? {
        if let existing = controllers[id] { return existing }
        guard let controller = try? TerminalController(terminalID: id, cols: cols, rows: rows)
        else { return nil }
        controller.connect(socketPath: socketPath, cols: cols, rows: rows)
        controllers[id] = controller
        return controller
    }

    func closeController(_ id: UInt64) {
        controllers[id]?.disconnect()
        controllers[id] = nil
    }
}
