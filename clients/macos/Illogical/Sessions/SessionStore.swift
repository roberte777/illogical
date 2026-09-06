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

    /// Splits waiting for their host to say which terminal it made.
    ///
    /// A queue, not one slot. Two ⌘Ds in quick succession both went out before
    /// either reply landed, the second overwrote the first, and the first
    /// reply then fell through to `pendingTab` -- so one split silently became
    /// a tab *and* stole the selection. Answered oldest-first per host, which
    /// is the order the server replies in on one connection.
    private struct PendingSplit {
        var host: ServerHost
        var tab: TabLayout.ID
        var pane: UUID
        var direction: SplitNode.Direction
    }
    private var pendingSplits: [PendingSplit] = []
    /// A plain new terminal waiting for the same, so its tab can be selected
    /// once the list arrives.
    private var pendingTab: TerminalRef?
    /// Terminals we have asked a server to kill. Their panes are already gone
    /// from the layout, so the reconcile must not put them back while the
    /// server still lists them.
    private var closing: Set<TerminalRef> = []

    /// Where remembered hosts are written.
    ///
    /// Injectable so tests do not scribble on the developer's real defaults --
    /// two of them did, and also spawned a real `ssh build-box` per run, which
    /// is the opposite of what this file's own header claims ("driven without
    /// a socket").
    private let defaults: HostDefaults

    /// `hosts: nil` means "whatever was remembered", read through `defaults`.
    ///
    /// Not defaulted to `startingHosts()` directly: that reads
    /// `UserDefaults.standard` regardless of what is passed here, so
    /// `SessionStore(defaults: InMemoryDefaults())` would have loaded the
    /// developer's own remembered hosts and, on `connect()`, spawned real `ssh`
    /// processes out of a unit test. Half a seam is worse than none -- it reads
    /// as isolated and is not.
    init(
        hosts: [ServerHost]? = nil,
        defaults: HostDefaults = UserDefaults.standard
    ) {
        self.defaults = defaults
        for host in hosts ?? SessionStore.startingHosts(defaults) {
            adopt(HostConnection(host: host))
        }
    }

    /// The local daemon, plus whichever remote hosts were added last time.
    ///
    /// ILLOGICAL_HOSTS is a comma-separated list of SSH destinations added at
    /// launch and not remembered. Same purpose as ILLOGICAL_SPLIT and
    /// ILLOGICAL_OPEN_SESSION_MENU: a window with two machines in it can be
    /// inspected — or screenshotted — without driving the mouse.
    static func startingHosts(_ defaults: HostDefaults = UserDefaults.standard) -> [ServerHost] {
        var hosts: [ServerHost] = [.local(socketPath: defaultSocketPath)]
        for host in environmentHosts() where !hosts.contains(host) {
            hosts.append(host)
        }
        for host in RemoteHostStore.load(defaults) where !hosts.contains(host) {
            hosts.append(host)
        }
        return hosts
    }

    /// The hosts ILLOGICAL_HOSTS named, deduplicated.
    ///
    /// Deduplicated because two entries for one destination is two
    /// `HostConnection`s to one machine -- two control connections, a duplicate
    /// id in the dropdown's `ForEach`, and two tabs per terminal, since the
    /// reconcile's "already shown" set is computed before the append loop.
    static func environmentHosts() -> [ServerHost] {
        guard let list = ProcessInfo.processInfo.environment["ILLOGICAL_HOSTS"] else { return [] }
        var seen: [ServerHost] = []
        for name in list.split(separator: ",") {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let host = ServerHost.ssh(destination: trimmed)
            if !seen.contains(host) { seen.append(host) }
        }
        return seen
    }

    /// What `RemoteHostStore` should hold: the remote hosts the *user* added.
    ///
    /// Not the ones ILLOGICAL_HOSTS injected. `addHost` and `removeHost` used to
    /// save the whole list, so adding or forgetting anything in a session
    /// started with that variable wrote its hosts to disk permanently -- which
    /// is the opposite of what it and the docs promise.
    /// `injected` is a parameter so a test can supply one: `ILLOGICAL_HOSTS` is
    /// read from `ProcessInfo`, which cannot be changed underneath a running
    /// process, so with it hardcoded the whole of this filter was untestable --
    /// and duly landed untested.
    func hostsToRemember(injected injectedHosts: [ServerHost]) -> [ServerHost] {
        let injected = Set(injectedHosts)
        // A host that is on disk *and* in this window stays on disk, even when
        // ILLOGICAL_HOSTS also names it. `startingHosts` dedupes the injected
        // list against the saved one, so provenance is otherwise lost: a host
        // the user added last week and that ILLOGICAL_HOSTS also names today
        // would be classed as injected and silently dropped the next time
        // anything else was added or forgotten.
        //
        // Not "anything on disk stays on disk": the filter is over `hosts`, so
        // a saved host absent from this window is dropped. That is unreachable
        // today because the app's only `SessionStore` is built from
        // `startingHosts()`, which loads every saved one -- but it is what the
        // expression does, and a second construction site would find out.
        let saved = Set(RemoteHostStore.load(defaults))
        return hosts.map(\.host).filter {
            $0.isRemote && (!injected.contains($0) || saved.contains($0))
        }
    }

    private var hostsToRemember: [ServerHost] {
        hostsToRemember(injected: Self.environmentHosts())
    }

    // MARK: - Hosts

    func host(_ id: ServerHost) -> HostConnection? {
        hosts.first { $0.host == id }
    }

    /// The host the next new terminal belongs on: whichever one the front tab
    /// is looking at.
    ///
    /// The fallback prefers a host that is actually connected. `hosts.first` is
    /// always the local daemon, and `createTerminal` sends through `try?`, so
    /// with no local `illogicald` running and a working remote, every ⌘T, every
    /// "+" and every New Session went to the dead host and did nothing at all --
    /// silently, with no tab, no error, and nothing on screen saying why.
    /// A host still connecting is preferred over one that has failed, for the
    /// same reason: during an ssh handshake nothing is connected yet, and
    /// falling through to a dead local daemon put ⌘T back to doing nothing.
    var selectedHost: HostConnection? {
        if let ref = selectedTab?.session.host, let host = host(ref) { return host }
        return hosts.first { $0.status.isConnected }
            ?? hosts.first { $0.status.isConnecting }
            ?? hosts.first
    }

    /// Add a machine and connect to it. A destination already in the list is
    /// selected rather than duplicated.
    func addHost(_ host: ServerHost) {
        if let existing = self.host(host) {
            // Already here. Adding it again is somebody asking for it to work,
            // so take the retry rather than the duplicate.
            if !existing.status.isConnected { existing.connect() }
            return
        }
        addHost(host, connect: true)
    }

    /// `connect: false` adds and remembers the host without dialling it. Only
    /// the tests pass false; everything in the app wants the connection.
    func addHost(_ host: ServerHost, connect: Bool) {
        guard self.host(host) == nil else { return }
        let connection = HostConnection(host: host)
        adopt(connection)
        RemoteHostStore.save(hostsToRemember, to: defaults)
        if connect { connection.connect() }
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
        RemoteHostStore.save(hostsToRemember, to: defaults)
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
        connection.onCreatesVoided = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.pendingSplits.removeAll { $0.host == connection.host }
        }
        hosts.append(connection)
    }

    func connect() {
        for host in hosts { host.connect() }
    }

    /// Whether nothing at all is reachable, and the message to show if so.
    ///
    /// One unreachable machine is not this: the window still works, and the
    /// dropdown marks that host. Only *every* host being down is worth taking
    /// the terminal area over for.
    ///
    /// A host that has not answered yet says nothing, so the first moments of
    /// a launch do not flash a failure at somebody.
    ///
    /// No revision counter behind this. There was one, on the theory that a
    /// view reading no host would not redraw -- but this reads every host's
    /// `status`, and `HostConnection` is `@Observable`, so the dependency is
    /// already registered by the read below.
    /// Nor is a machine we have not finished dialling. A host only reports
    /// `.connected` once its first `session_list` proves the far end is really
    /// there, and over SSH everything before that -- auth, the remote spawn,
    /// the list itself -- is a second or more. Without this, launching with no
    /// local daemon and one remote put "No illogicald at ..." over the whole
    /// window for the length of the handshake and then flipped to the remote's
    /// tabs. Worse, the only button on that screen is Try Again, which
    /// reconnects every host -- so a user who believed it killed the ssh
    /// connection a moment before it would have succeeded, and could keep
    /// doing so indefinitely.
    var connectionError: String? {
        guard !hosts.isEmpty else { return nil }
        guard !hosts.contains(where: { $0.status.isConnected || $0.status.isConnecting })
        else { return nil }
        return hosts.compactMap(\.status.message).first
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
        pendingSplits.append(
            PendingSplit(host: host.host, tab: tabID, pane: paneID, direction: direction))
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
            let wasInFront = selectedTab?.session
            tabs.remove(at: index)
            repairSelection(preferring: wasInFront)
        }
    }

    /// Close a whole tab, and every terminal in it.
    func closeTab(_ tabID: TabLayout.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        for pane in tabs[index].panes { kill(pane.terminal) }
        let wasInFront = selectedTab?.session
        tabs.remove(at: index)
        repairSelection(preferring: wasInFront)
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
        // The oldest split still waiting on *this* host. Matching the host
        // matters: two machines answer independently, and a reply from one must
        // not consume the other's pending split.
        //
        // Matched on host alone, and always retired. Requiring the tab to still
        // exist left dead entries in the queue forever -- `TabLayout.id` is a
        // fresh UUID, so a closed tab can never come back to claim one -- and
        // worse, the reply that should have retired it was matched against the
        // *next* entry instead, splicing a terminal created in one session into
        // a tab belonging to another.
        //
        // Position is the only correlation there is: `created` carries a
        // terminal id and no request id. That makes this queue correct exactly
        // while every request produces exactly one reply, which is why
        // `HostConnection.voidPendingCreates` exists -- a request that can no
        // longer be answered has to take its entry with it, or the queue is one
        // out of step for the life of the process and every later split lands
        // in the tab before last.
        guard let index = pendingSplits.firstIndex(where: { $0.host == ref.host }) else {
            pendingTab = ref
            return
        }
        let pending = pendingSplits.remove(at: index)
        guard let tab = tabs.firstIndex(where: { $0.id == pending.tab }) else {
            // Its tab closed while the server was answering. The terminal is
            // real, so it gets a tab of its own rather than being dropped.
            pendingTab = ref
            return
        }
        let pane = Pane(terminal: ref)
        tabs[tab].root = tabs[tab].root.splitting(
            pending.pane, with: pane, direction: pending.direction)
        tabs[tab].focused = pane.id
        selectedTabID = pending.tab
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
        // Read *before* the prune, so the repair below knows where the user
        // actually was rather than where a previous reconcile left a cache.
        let wasInFront = selectedTab?.session
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

        repairSelection(preferring: wasInFront)

        if let direction = pendingLaunchSplit, selectedTab != nil {
            pendingLaunchSplit = nil
            split(direction)
        }
    }

    /// Put the selection somewhere sensible after the tab list changed.
    ///
    /// The only place `selectedTabID` is repaired. `closePane` and `closeTab`
    /// used to do their own `tabs.first?.id`, which is how closing the last tab
    /// of a remote session teleported the window to the local machine: the
    /// session button changed host and the strip's contents changed with it.
    /// Prefer the session that was in front, then any tab on that machine,
    /// then anything at all.
    private func repairSelection(preferring wanted: SessionRef?) {
        if let id = selectedTabID, tabs.contains(where: { $0.id == id }) { return }
        selectedTabID =
            tabs.first { $0.session == wanted }?.id
            ?? tabs.first { $0.session.host == wanted?.host }?.id
            ?? tabs.first?.id
    }

    // MARK: - Per-terminal connections

    /// The controller for a terminal, creating and attaching one if needed.
    func controller(for ref: TerminalRef, cols: UInt16, rows: UInt16) -> TerminalController? {
        host(ref.host)?.controller(for: ref.terminal, cols: cols, rows: rows)
    }

    /// The controller for a terminal, if one is open. For views, which must
    /// not attach one as a side effect of being drawn.
    func existingController(for ref: TerminalRef) -> TerminalController? {
        host(ref.host)?.existingController(ref.terminal)
    }

    func closeController(_ ref: TerminalRef) {
        host(ref.host)?.closeController(ref.terminal)
    }
}

/// The little of `UserDefaults` that remembering hosts actually needs.
///
/// A protocol so the tests can hand over something in memory. Suites work, but
/// `cfprefsd` writes their plists lazily, so removing one in `tearDown` races
/// the write and leaves files in ~/Library/Preferences — which is how a change
/// meant to stop tests touching the developer's preferences ended up creating
/// twenty-seven files instead of polluting one domain.
protocol HostDefaults: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: HostDefaults {}

/// The remote hosts this window remembers.
///
/// A destination and the remote binary's name, and nothing else: no
/// credentials, no keys, no port — `ssh` reads the user's own config, and a
/// `Host` alias from it is a perfectly good destination.
enum RemoteHostStore {
    static let key = "remoteHosts"

    static func load(_ defaults: HostDefaults = UserDefaults.standard) -> [ServerHost] {
        guard let data = defaults.data(forKey: key),
            let hosts = try? JSONDecoder().decode([ServerHost].self, from: data)
        else { return [] }
        return hosts.filter(\.isRemote)
    }

    static func save(_ hosts: [ServerHost], to defaults: HostDefaults = UserDefaults.standard) {
        guard let data = try? JSONEncoder().encode(hosts.filter(\.isRemote)) else { return }
        defaults.set(data, forKey: key)
    }
}
