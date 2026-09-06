//  SessionStore.swift
//  The window: which hosts it is connected to, and which of their terminals
//  are drawn where.
//
//  A host owns what exists (HostConnection). The store owns where it is drawn.
//  Keeping that split is what makes several machines in one window a change
//  here and nowhere else: a `TerminalRef` carries its host, and every layer
//  above the transport is identical whether a terminal's PTY is on this
//  machine or another one.

import AppKit
import Foundation
import IllogicalProtocol
import Observation

@MainActor
@Observable
final class SessionStore {
    /// Every machine this window is talking to. The first is always the local
    /// daemon; the rest were added by the user and are remembered.
    private(set) var hosts: [HostConnection] = []

    /// Tabs, each a layout of panes. A tab is not a terminal: splitting adds
    /// a pane and a connection without adding a tab. A tab belongs to one
    /// session on one host — panes from two machines never share a tab,
    /// because a session is a thing that lives on a machine.
    var tabs: [TabLayout] = []
    var selectedTabID: TabLayout.ID?

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

    /// A split waiting for its host to say which terminal it made.
    private var pendingSplit:
        (
            host: ServerHost, tab: TabLayout.ID, pane: UUID, direction: SplitNode.Direction
        )?
    /// A plain new terminal waiting for the same, so its tab can be selected
    /// once the list arrives.
    private var pendingTab: TerminalRef?
    /// Terminals we have asked a server to kill. Their panes are already gone
    /// from the layout, so the reconcile must not put them back while the
    /// server still lists them.
    private var closing: Set<TerminalRef> = []

    init(hosts: [ServerHost] = SessionStore.startingHosts()) {
        for host in hosts { adopt(HostConnection(host: host)) }
    }

    /// The local daemon, plus whichever remote hosts were added last time.
    ///
    /// ILLOGICAL_HOSTS is a comma-separated list of SSH destinations added at
    /// launch and not remembered. Same purpose as ILLOGICAL_SPLIT and
    /// ILLOGICAL_OPEN_SESSION_MENU: a window with two machines in it can be
    /// inspected — or screenshotted — without driving the mouse.
    static func startingHosts() -> [ServerHost] {
        var hosts: [ServerHost] = [.local(socketPath: defaultSocketPath)]
        if let list = ProcessInfo.processInfo.environment["ILLOGICAL_HOSTS"] {
            hosts += list.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { ServerHost.ssh(destination: $0) }
        }
        for host in RemoteHostStore.load() where !hosts.contains(host) {
            hosts.append(host)
        }
        return hosts
    }

    // MARK: - Hosts

    func host(_ id: ServerHost) -> HostConnection? {
        hosts.first { $0.host == id }
    }

    /// The host the next new terminal belongs on: whichever one the front tab
    /// is looking at.
    var selectedHost: HostConnection? {
        if let ref = selectedTab?.session.host, let host = host(ref) { return host }
        return hosts.first
    }

    /// Add a machine and connect to it. A destination already in the list is
    /// selected rather than duplicated.
    func addHost(_ host: ServerHost) {
        if let existing = self.host(host) {
            if case .failed = existing.status { existing.connect() }
            return
        }
        let connection = HostConnection(host: host)
        adopt(connection)
        RemoteHostStore.save(hosts.map(\.host).filter(\.isRemote))
        connection.connect()
    }

    /// Forget a machine: close everything of its, and take its tabs with it.
    ///
    /// The local host cannot be removed — there would be nothing left to make
    /// a terminal on, and it is not something the user added.
    func removeHost(_ host: ServerHost) {
        guard host.isRemote, let index = hosts.firstIndex(where: { $0.host == host }) else {
            return
        }
        hosts[index].disconnect()
        hosts.remove(at: index)
        RemoteHostStore.save(hosts.map(\.host).filter(\.isRemote))
        reconcileTabs()
    }

    /// Try a host again after a failure.
    func reconnect(_ host: ServerHost) {
        self.host(host)?.connect()
    }

    private func adopt(_ connection: HostConnection) {
        connection.onListChanged = { [weak self, weak connection] in
            guard let self, let connection else { return }
            connection.pruneControllers()
            self.reconcileTabs()
        }
        connection.onCreated = { [weak self, weak connection] terminal in
            guard let self, let connection else { return }
            self.terminalCreated(connection.ref(terminal))
        }
        connection.onStatusChanged = { [weak self] in
            // Observation only tracks what a view read, and a view that read
            // no host would not redraw on a status change it does not own.
            self?.hostStatusRevision &+= 1
        }
        hosts.append(connection)
    }

    /// Bumped whenever any host's status changes, so a view showing the state
    /// of the *set* of hosts has something of the store's own to observe.
    private(set) var hostStatusRevision: UInt64 = 0

    func connect() {
        for host in hosts { host.connect() }
    }

    /// Whether nothing at all is reachable, and the message to show if so.
    ///
    /// A single failed remote host is not this: the window still works, and
    /// the menu marks that host. Only every host being down is worth taking
    /// the terminal area over for.
    var connectionError: String? {
        _ = hostStatusRevision
        guard !hosts.isEmpty else { return nil }
        let failures = hosts.compactMap { host -> String? in
            if case .failed(let message) = host.status { return message }
            return nil
        }
        guard failures.count == hosts.count else { return nil }
        return failures.first
    }

    // MARK: - The window's view of what exists

    var selectedTab: TabLayout? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The terminal in front: the focused pane of the front tab.
    var selectedRef: TerminalRef? { selectedTab?.focusedTerminal }

    var selected: TerminalSummary? {
        guard let ref = selectedRef else { return nil }
        return terminal(ref)
    }

    var selectedSession: SessionRef? {
        if let tab = selectedTab { return tab.session }
        guard let host = hosts.first, let session = host.sessions.first else { return nil }
        return SessionRef(host: host.host, session: session.id)
    }

    var selectedSessionSummary: SessionSummary? {
        guard let ref = selectedSession else { return nil }
        return host(ref.host)?.sessions.first { $0.id == ref.session }
    }

    /// Tabs in the session that is currently in front. A session lives on one
    /// host, so this is also "tabs on the machine you are looking at".
    var visibleTabs: [TabLayout] {
        guard let session = selectedSession else { return tabs }
        return tabs.filter { $0.session == session }
    }

    func terminal(_ ref: TerminalRef) -> TerminalSummary? {
        host(ref.host)?.terminal(ref.terminal)
    }

    /// The terminal whose name the tab carries.
    func label(for tab: TabLayout) -> TerminalSummary? {
        tab.focusedTerminal.flatMap { terminal($0) }
    }

    /// The machine a tab is on, for a label. Nil when it is the local one,
    /// because "Local" in front of every tab on a laptop is noise.
    func remoteName(for tab: TabLayout) -> String? {
        tab.session.host.isRemote ? tab.session.host.displayName : nil
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

    // MARK: - Creating and killing

    func refresh() {
        for host in hosts { host.refresh() }
    }

    /// Make a terminal on a host. Defaults to the machine the front tab is on,
    /// in the session it is in.
    func createTerminal(sessionName: String? = nil, on host: ServerHost? = nil) {
        let target = host.flatMap { self.host($0) } ?? selectedHost
        guard let target else { return }
        let name = sessionName ?? frontSessionName(on: target) ?? "default"
        pendingSplit = nil
        target.createTerminal(sessionName: name)
    }

    /// The session a new terminal on `host` should join: the one in front if
    /// it is on that machine, otherwise that machine's first.
    private func frontSessionName(on host: HostConnection) -> String? {
        if let ref = selectedSession, ref.host == host.host,
            let match = host.sessions.first(where: { $0.id == ref.session })
        {
            return match.name
        }
        return host.sessions.first?.name
    }

    func kill(_ ref: TerminalRef) {
        // The server signals the child; the terminal is retired when it
        // actually exits, and we find out from `sessions_changed`.
        closing.insert(ref)
        host(ref.host)?.kill(ref.terminal)
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
        guard let tab = tabs.first(where: { $0.id == tabID }),
            let host = host(tab.session.host)
        else { return }
        let name =
            host.sessions.first { $0.id == tab.session.session }?.name
            ?? host.sessions.first?.name ?? "default"
        // The pane appears when the server answers with a terminal id. Over a
        // unix socket that is one round trip; a placeholder pane would be more
        // machinery than the wait is worth. Over SSH it is a round trip on an
        // already-open channel, which is the same order of magnitude.
        pendingSplit = (host: host.host, tab: tabID, pane: paneID, direction: direction)
        host.createTerminal(sessionName: name)
    }

    /// Close one pane. The last pane in a tab closes the tab.
    func closePane(_ paneID: UUID, in tabID: TabLayout.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
            let pane = tabs[index].root.pane(paneID)
        else { return }

        kill(pane.terminal)

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
        for pane in tabs[index].panes { kill(pane.terminal) }
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

    // MARK: - Reconciling

    private func terminalCreated(_ ref: TerminalRef) {
        if let pending = pendingSplit, pending.host == ref.host,
            let index = tabs.firstIndex(where: { $0.id == pending.tab })
        {
            pendingSplit = nil
            let pane = Pane(terminal: ref)
            tabs[index].root = tabs[index].root.splitting(
                pending.pane, with: pane, direction: pending.direction)
            tabs[index].focused = pane.id
            selectedTabID = pending.tab
        } else {
            pendingTab = ref
        }
    }

    /// Bring the tab list back in line with what every host says exists.
    ///
    /// Internal rather than private so the tests can drive it directly: it is
    /// the only place tabs are created or destroyed, and every interesting
    /// case is a race between what a server lists and what we already did.
    ///
    /// Three jobs: drop panes whose terminal is gone, give every terminal that
    /// is in no tab a tab of its own, and keep the selection pointing at
    /// something. Across every host at once, because a pane and the tab it
    /// sits in are the window's, not a connection's.
    func reconcileTabs() {
        let live = Set(hosts.flatMap { host in host.terminals.map { host.ref($0.id) } })
        closing.formIntersection(live)

        tabs = tabs.compactMap { tab in
            var tab = tab
            // A host that has been removed takes its tabs with it, even though
            // it is no longer here to say its terminals are gone.
            guard host(tab.session.host) != nil else { return nil }
            for pane in tab.panes where !live.contains(pane.terminal) {
                guard let root = tab.root.removing(pane.id) else { return nil }
                tab.root = root
            }
            tab.repairFocus()
            return tab
        }

        let shown = Set(tabs.flatMap { $0.panes.map(\.terminal) })
        for host in hosts {
            for terminal in host.terminals {
                let ref = host.ref(terminal.id)
                guard !shown.contains(ref), !closing.contains(ref) else { continue }
                tabs.append(
                    TabLayout(
                        session: SessionRef(host: host.host, session: terminal.session),
                        terminal: ref))
            }
        }

        if let pending = pendingTab,
            let tab = tabs.first(where: { $0.panes.contains { $0.terminal == pending } })
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
    func controller(for ref: TerminalRef, cols: UInt16, rows: UInt16) -> TerminalController? {
        host(ref.host)?.controller(for: ref.terminal, cols: cols, rows: rows)
    }

    func closeController(_ ref: TerminalRef) {
        host(ref.host)?.closeController(ref.terminal)
    }
}

/// The remote hosts this window remembers.
///
/// Only the destination is stored, because that is all there is: no
/// credentials, no keys, no port — `ssh` reads the user's own config, and a
/// `Host` alias from it is a perfectly good destination.
enum RemoteHostStore {
    static let key = "remoteHosts"

    static func load(_ defaults: UserDefaults = .standard) -> [ServerHost] {
        guard let data = defaults.data(forKey: key),
            let hosts = try? JSONDecoder().decode([ServerHost].self, from: data)
        else { return [] }
        return hosts.filter(\.isRemote)
    }

    static func save(_ hosts: [ServerHost], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(hosts.filter(\.isRemote)) else { return }
        defaults.set(data, forKey: key)
    }
}
