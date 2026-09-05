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
    /// Tabs, each a layout of panes. A tab is not a terminal: splitting adds
    /// a pane and a connection without adding a tab.
    var tabs: [TabLayout] = []
    var selectedTabID: TabLayout.ID?
    var connectionError: String?
    /// The toolbar lives in a title bar accessory and the menu lives in the
    /// content view, so the open/closed state has to be somewhere both can see.
    ///
    /// ILLOGICAL_OPEN_SESSION_MENU opens it at launch, alongside
    /// ILLOGICAL_TRACE, so it can be screenshotted without driving the mouse.
    var sessionMenuOpen =
        ProcessInfo.processInfo.environment["ILLOGICAL_OPEN_SESSION_MENU"] != nil

    /// ILLOGICAL_SPLIT=columns|rows splits the first tab once, as soon as
    /// there is one. Same purpose as ILLOGICAL_OPEN_SESSION_MENU: the layout
    /// can be inspected — or screenshotted — without driving the mouse.
    private var pendingLaunchSplit: SplitNode.Direction? = {
        switch ProcessInfo.processInfo.environment["ILLOGICAL_SPLIT"] {
        case "columns": .columns
        case "rows": .rows
        default: nil
        }
    }()

    /// Live controllers, one per open terminal.
    private(set) var controllers: [UInt64: TerminalController] = [:]

    private var control: Connection?
    private var pump: Task<Void, Never>?

    /// A split waiting for the server to say which terminal it made.
    private var pendingSplit: (tab: TabLayout.ID, pane: UUID, direction: SplitNode.Direction)?
    /// A plain new terminal waiting for the same, so its tab can be selected
    /// once the list arrives.
    private var pendingTab: UInt64?
    /// Terminals we have asked the server to kill. Their panes are already
    /// gone from the layout, so the reconcile must not put them back while
    /// the server still lists them.
    private var closing: Set<UInt64> = []

    var selectedTab: TabLayout? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The terminal in front: the focused pane of the front tab.
    var selectedID: TerminalSummary.ID? { selectedTab?.focusedTerminal }

    var selected: TerminalSummary? {
        guard let selectedID else { return nil }
        return terminals.first { $0.id == selectedID }
    }

    var selectedSession: SessionSummary? {
        guard let tab = selectedTab else { return sessions.first }
        return sessions.first { $0.id == tab.session }
    }

    /// Tabs in the session that is currently in front.
    var visibleTabs: [TabLayout] {
        guard let session = selectedSession else { return tabs }
        return tabs.filter { $0.session == session.id }
    }

    func terminal(_ id: UInt64) -> TerminalSummary? {
        terminals.first { $0.id == id }
    }

    /// The terminal whose name the tab carries.
    func label(for tab: TabLayout) -> TerminalSummary? {
        tab.focusedTerminal.flatMap { terminal($0) }
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
        pendingSplit = nil
        try? control?.send(.create, json: CreateBody(sessionName: name, cols: 120, rows: 40))
    }

    func kill(_ id: UInt64) {
        // The server signals the child; the terminal is retired when it
        // actually exits, and we find out from `sessions_changed`.
        closing.insert(id)
        try? control?.send(.kill, terminal: id)
        closeController(id)
    }

    // MARK: - Splits
    //
    // A split is a new terminal on the server and a new connection to it.
    // Nothing about the layout leaves this process: the server never divides
    // a grid, and closing a split is closing a connection. See docs/GOALS.md.

    /// Split the focused pane of the front tab.
    func split(_ direction: SplitNode.Direction) {
        guard let tab = selectedTab else { return }
        split(pane: tab.focused, in: tab.id, direction: direction)
    }

    func split(pane paneID: UUID, in tabID: TabLayout.ID, direction: SplitNode.Direction) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let name = sessions.first { $0.id == tab.session }?.name ?? "default"
        // The pane appears when the server answers with a terminal id. Over a
        // unix socket that is one round trip; a placeholder pane would be more
        // machinery than the wait is worth.
        pendingSplit = (tab: tabID, pane: paneID, direction: direction)
        try? control?.send(.create, json: CreateBody(sessionName: name, cols: 120, rows: 40))
    }

    /// Close one pane. The last pane in a tab closes the tab.
    func closePane(_ paneID: UUID, in tabID: TabLayout.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
            let pane = tabs[index].root.pane(paneID)
        else { return }

        kill(pane.terminalID)

        // Take it out of the layout now rather than waiting for the server to
        // confirm: the connection is already closed, so the pane would render
        // a dead terminal in the meantime.
        if let root = tabs[index].root.removing(paneID) {
            tabs[index].root = root
            tabs[index].repairFocus()
        } else {
            tabs.remove(at: index)
            if selectedTabID == tabID { selectedTabID = tabs.first?.id }
        }
    }

    /// Close a whole tab, and every terminal in it.
    func closeTab(_ tabID: TabLayout.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        for pane in tabs[index].panes { kill(pane.terminalID) }
        tabs.remove(at: index)
        if selectedTabID == tabID { selectedTabID = tabs.first?.id }
    }

    func closeFocusedPane() {
        guard let tab = selectedTab else { return }
        closePane(tab.focused, in: tab.id)
    }

    /// Make one pane fill its tab, or put the tree back.
    func toggleZoom(_ paneID: UUID, in tabID: TabLayout.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].isSplit else {
            return
        }
        tabs[index].zoomed = tabs[index].zoomed == paneID ? nil : paneID
        tabs[index].focused = paneID
    }

    func toggleZoomOnFocusedPane() {
        guard let tab = selectedTab else { return }
        toggleZoom(tab.focused, in: tab.id)
    }

    func focus(_ paneID: UUID, in tabID: TabLayout.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
            tabs[index].focused != paneID
        else { return }
        tabs[index].focused = paneID
    }

    /// Move focus geometrically, the way ⌥⌘arrow does in every split view.
    func moveFocus(_ direction: SplitNode.FocusDirection) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        guard tabs[index].zoomed == nil else { return }
        guard let next = tabs[index].root.pane(direction, of: tabs[index].focused) else { return }
        tabs[index].focused = next.id
    }

    func setRatio(_ ratio: Double, forSplit splitID: UUID, in tabID: TabLayout.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].root = tabs[index].root.settingRatio(ratio, forSplit: splitID)
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
            reconcileTabs(live: live)

        case .created:
            guard let created = try? JSONDecoder().decode(CreatedBody.self, from: frame.payload)
            else { return }
            if let pending = pendingSplit,
                let index = tabs.firstIndex(where: { $0.id == pending.tab })
            {
                pendingSplit = nil
                let pane = Pane(terminalID: created.terminal)
                tabs[index].root = tabs[index].root.splitting(
                    pending.pane, with: pane, direction: pending.direction)
                tabs[index].focused = pane.id
                selectedTabID = pending.tab
            } else {
                pendingTab = created.terminal
            }
            refresh()

        case .sessionsChanged:
            refresh()

        default:
            break
        }
    }

    /// Bring the tab list back in line with what the server says exists.
    ///
    /// Internal rather than private so the tests can drive it directly: it is
    /// the only place tabs are created or destroyed, and every interesting
    /// case is a race between what the server lists and what we already did.
    ///
    /// Three jobs: drop panes whose terminal is gone, give every terminal that
    /// is in no tab a tab of its own, and keep the selection pointing at
    /// something.
    func reconcileTabs(live: Set<UInt64>) {
        closing.formIntersection(live)

        tabs = tabs.compactMap { tab in
            var tab = tab
            for pane in tab.panes where !live.contains(pane.terminalID) {
                guard let root = tab.root.removing(pane.id) else { return nil }
                tab.root = root
            }
            tab.repairFocus()
            return tab
        }

        let shown = Set(tabs.flatMap { $0.panes.map(\.terminalID) })
        for terminal in terminals
        where !shown.contains(terminal.id) && !closing.contains(terminal.id) {
            tabs.append(TabLayout(session: terminal.session, terminalID: terminal.id))
        }

        if let pending = pendingTab,
            let tab = tabs.first(where: { $0.panes.contains { $0.terminalID == pending } })
        {
            selectedTabID = tab.id
            pendingTab = nil
        }

        if selectedTabID == nil || !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = tabs.first?.id
        }

        if let direction = pendingLaunchSplit, selectedTab != nil {
            pendingLaunchSplit = nil
            split(direction)
        }
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
