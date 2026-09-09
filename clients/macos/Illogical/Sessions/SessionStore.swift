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

    /// The machine the window is on: where ⌘T makes a terminal, whose sessions
    /// the strip draws, and what the session button names.
    ///
    /// Stored, not derived from the front tab. Derived, "which machine" could
    /// only ever be a machine with a terminal on it — so Switch Host had
    /// nowhere to put you on an empty one, and a window with no tabs at all had
    /// to guess. It guessed "the first host that is connected", which is a
    /// perfectly good answer to a question nobody asked and sent ⌘T to a
    /// machine nothing on screen named.
    ///
    /// Always one of `hosts`: set at init, moved by the selection funnel below,
    /// and put back by `removeHost` when the machine it names is forgotten.
    private(set) var currentHost: ServerHost

    /// The session last in front on each machine, so that coming back to one
    /// lands where you left it rather than on its first tab.
    ///
    /// Never pruned. An entry for a session that has since been deleted costs
    /// a `SessionRef`, and `switchHost` validates it against the host's own
    /// list before using it; pruning would mean walking this on every list from
    /// every host to save nothing anybody can measure.
    private var lastSession: [ServerHost: SessionRef] = [:]

    /// Tabs, each a layout of panes. A tab is not a terminal: splitting adds
    /// a pane and a connection without adding a tab. A tab belongs to one
    /// session on one host — panes from two machines never share a tab,
    /// because a session is a thing that lives on a machine.
    var tabs: [TabLayout] = []

    /// The tab in front, or nil when the machine you are on has nothing to
    /// show.
    ///
    /// The `didSet` is the one funnel selecting a tab goes through, and it is a
    /// `didSet` rather than a `select(_:)` method because this is written
    /// directly from the tab strip, the dropdown, the menu bar, the split reply
    /// and the tests — a call site that forgot the method would leave the
    /// toolbar naming one machine while ⌘T made a terminal on another, which is
    /// exactly the disagreement `currentHost` exists to end.
    var selectedTabID: TabLayout.ID? {
        didSet { selectionChanged() }
    }

    /// The destructive thing a dialog is currently asking about, or nil.
    ///
    /// One slot rather than a flag per action: only one confirmation can be on
    /// screen at a time, and the dialog reads its wording off the value.
    var pendingDestruction: PendingDestruction?

    /// The toolbar lives in a title bar accessory and the menu lives in the
    /// content view, so the open/closed state has to be somewhere both can see.
    ///
    /// ILLOGICAL_OPEN_SESSION_MENU opens it at launch, alongside
    /// ILLOGICAL_TRACE, so it can be screenshotted without driving the mouse.
    var sessionMenuOpen =
        ProcessInfo.processInfo.environment["ILLOGICAL_OPEN_SESSION_MENU"] != nil

    /// A session the menu bar has asked the dropdown to rename in place.
    ///
    /// The rename field lives in `SessionMenu`, which only exists while the
    /// menu is open, so File ▸ Rename Session… has nothing to reach directly.
    /// It leaves the session here and opens the menu; the menu consumes it on
    /// appear. Nil the rest of the time, including immediately after the menu
    /// has taken it — a value left behind would re-arm the field the next time
    /// the menu opened for some quite different reason.
    var pendingRename: SessionRef?

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
    ///
    /// Readable so a test can assert the *absence* of a kill. "⌘W declined"
    /// has to mean nothing was hung up: closing the window leaves every
    /// terminal in it running, which is the promise the empty state makes in
    /// as many words. The reconcile only consults this when *adding* tabs, so
    /// a re-list is not a way to observe it.
    private(set) var closing: Set<TerminalRef> = []

    /// The session this window was on last time it ran, until the machine it
    /// names has answered. `reconcileTabs` spends it on that machine's first
    /// list; anything the user selects first voids it, because a restore that
    /// overrode a person reaching for a tab would be selection theft.
    private var pendingRestore: FrontSession?

    /// What `FrontSessionStore` already holds, so that ⌘1/⌘2 inside one session
    /// does not rewrite a value that has not changed.
    private var writtenFront: FrontSession?

    /// Where remembered hosts are written.
    ///
    /// Injectable so tests do not scribble on the developer's real defaults --
    /// two of them did, and also spawned a real `ssh build-box` per run, which
    /// is the opposite of what this file's own header claims ("driven without
    /// a socket").
    private let defaults: HostDefaults

    /// What every `HostConnection` here uses to start a local server. Only the
    /// local host ever calls it; a remote one has no bundle to start anything
    /// from.
    private let launcher: DaemonLauncher

    /// `hosts: nil` means "whatever was remembered", read through `defaults`.
    ///
    /// Not defaulted to `startingHosts()` directly: that reads
    /// `UserDefaults.standard` regardless of what is passed here, so
    /// `SessionStore(defaults: InMemoryDefaults())` would have loaded the
    /// developer's own remembered hosts and, on `connect()`, spawned real `ssh`
    /// processes out of a unit test. Half a seam is worse than none -- it reads
    /// as isolated and is not.
    /// `launcher` is what starts a local server when there is none, and is
    /// injected for the same reason `defaults` is: a test that reaches
    /// `connect()` on a `.local` host would otherwise run the real one. It is
    /// threaded through every `HostConnection` this store makes, `addHost`
    /// included -- a store with a recording launcher and a host that quietly
    /// had the real one is a seam that reads as isolated and is not.
    ///
    /// The front session is read here too, from the same `defaults` and in the
    /// same breath: it is one `data(forKey:)`, nothing waits on the network,
    /// and the window therefore opens on the machine it was left on rather than
    /// opening on the local daemon and being yanked elsewhere a second later.
    /// docs/GOALS.md G7's launch budget is untouched — the read is off the
    /// first-paint path's critical section entirely, beside the one
    /// `startingHosts` already does.
    init(
        hosts: [ServerHost]? = nil,
        defaults: HostDefaults = UserDefaults.standard,
        launcher: DaemonLauncher = BundledDaemonLauncher()
    ) {
        self.defaults = defaults
        self.launcher = launcher
        let starting = hosts ?? SessionStore.startingHosts(defaults)
        let front = FrontSessionStore.load(defaults)
        writtenFront = front
        // A remembered machine that is no longer in the list — a host forgotten
        // since, or an ILLOGICAL_HOSTS window — is not somewhere to open on,
        // and neither is its session. `hosts.first` is the local daemon; the
        // last fallback is unreachable in the app and keeps this non-optional
        // rather than making every reader unwrap a thing that is always there.
        let remembered = front.map(\.host).flatMap { starting.contains($0) ? $0 : nil }
        currentHost = remembered ?? starting.first ?? .local(socketPath: Self.defaultSocketPath)
        pendingRestore = remembered == nil ? nil : front
        for host in starting {
            adopt(HostConnection(host: host, launcher: launcher))
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

    /// The connection to the machine the window is on. Nil only in the moment
    /// between a host being forgotten and the list being repaired.
    ///
    /// This replaced a `selectedHost` that read the front tab's host and, with
    /// no front tab, fell back to "the first host that is connected". The
    /// fallback was there because `createTerminal` sends through `try?`, so a
    /// ⌘T aimed at a dead local daemon did nothing at all, silently — but it
    /// answered that by quietly routing the terminal to some other machine.
    /// `currentHost` is now always a machine somebody chose, and a machine that
    /// cannot make a terminal says so on screen (`currentHostError`) instead of
    /// having its work done elsewhere.
    var current: HostConnection? { host(currentHost) }

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
        let connection = HostConnection(host: host, launcher: launcher)
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
        // The window cannot be left standing on a machine that is no longer
        // here: `hosts[0]` is the local daemon, which is the one host that
        // cannot be removed. Before the reconcile, because the repair it ends
        // with reads `currentHost` to decide what may keep the selection.
        if currentHost == host { currentHost = hosts[0].host }
        if pendingRestore?.host == host { pendingRestore = nil }
        reconcileTabs()
    }

    /// Try a host again after a failure.
    func reconnect(_ host: ServerHost) {
        self.host(host)?.connect()
    }

    /// Go to a machine: the session you were last on there, its first session
    /// when there is no memory of one, and the empty screen when it has none at
    /// all.
    ///
    /// The last case is the point of the whole feature. A machine with nothing
    /// on it is somewhere the window can be — you go there to make the first
    /// terminal on it — and until this there was no way to say so, because
    /// "which machine" was read off a tab.
    func switchHost(_ target: ServerHost) {
        // Already being there is not a move. The menu's checked row is still a
        // row you can click, and without this it would drop you on the first
        // tab of the session you are already in.
        guard let connection = host(target), target != currentHost else { return }
        currentHost = target
        // Validated at use rather than pruned: the remembered session may have
        // been deleted from another window since we were last there.
        let wanted =
            lastSession[target].flatMap { session($0) != nil ? $0 : nil }
            ?? connection.sessions.first.map { SessionRef(host: target, session: $0.id) }
        // Cleared first, so the repair below is a repair rather than a no-op:
        // the tab in front is still perfectly valid, it is just on the machine
        // being left.
        selectedTabID = nil
        repairSelection(preferring: wanted)
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
    ///
    /// Nor is one unreachable machine this while another is still dialling. A host only reports
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

    /// Why the machine in front cannot show anything, or nil when it can.
    ///
    /// Switch Host and the launch restore can both park the window on a machine
    /// that is unreachable, and the empty screen is the wrong thing to say
    /// there: its New Terminal button sends through `try?` on a connection that
    /// is not open, so it is a button that does nothing and gives no reason.
    ///
    /// Nil while a host is merely connecting — the first moments of a launch
    /// are not a failure — and nil whenever a tab is up, for the reason
    /// `ContentView` puts the tab first: a reconnect must not blank a live
    /// window over a dropped packet. The wording is `ssh`'s own complaint, by
    /// way of `Status.message`, so nothing new is invented here.
    var currentHostError: String? {
        guard selectedTab == nil else { return nil }
        return current?.status.message
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

    // MARK: - Find
    //
    // Menu items rather than a key monitor, for the reason ⌘1–⌘9 are: a chord
    // a menu claims never reaches `keyDown`, so it cannot also be typed into
    // the terminal. Which pane they act on is this store's question and not the
    // find bar's — there is one bar per terminal, and ⌘F means the one in
    // front.

    /// The controller for the terminal in front, if it has been attached to.
    var selectedController: TerminalController? {
        selectedRef.flatMap { existingController(for: $0) }
    }

    /// ⌘F. Opens the find bar over the focused pane, keeping whatever was last
    /// searched for.
    func beginFind() { selectedController?.search.open() }

    /// ⌘G and ⇧⌘G. Nothing when no bar is open: a find that reopened the bar
    /// would make the two chords mean different things depending on what was on
    /// screen a minute ago.
    func findNext() { selectedController?.search.selectNext() }
    func findPrevious() { selectedController?.search.selectPrevious() }

    /// Whether stepping between matches would do anything, so the menu says so.
    var canFindAgain: Bool { selectedController?.search.canStep ?? false }

    /// The session in front: the tab's, or — with no tab — the one the machine
    /// you are on was last showing, then its first.
    ///
    /// Never another machine's. This used to end at `hosts.first`, which is the
    /// local daemon, so a window sitting on a remote host with no tabs named a
    /// local session on the session button and offered Rename and Delete for
    /// it.
    var selectedSession: SessionRef? {
        if let tab = selectedTab { return tab.session }
        if let remembered = lastSession[currentHost], session(remembered) != nil {
            return remembered
        }
        guard let session = current?.sessions.first else { return nil }
        return SessionRef(host: currentHost, session: session.id)
    }

    var selectedSessionSummary: SessionSummary? {
        selectedSession.flatMap { session($0) }
    }

    /// What a host says about one of its sessions, by id.
    ///
    /// By id, never by name, which is the whole of what makes rename safe: a
    /// `SessionRef` survives a rename because the id does, and everywhere a
    /// name is *drawn* goes through here. See issue #37.
    func session(_ ref: SessionRef) -> SessionSummary? {
        host(ref.host)?.sessions.first { $0.id == ref.session }
    }

    /// Tabs in the session that is currently in front. A session lives on one
    /// host, so this is also "tabs on the machine you are looking at".
    ///
    /// With no session in front — a machine with nothing on it — that is an
    /// empty strip, not every host's tabs. It used to be `return tabs`, which
    /// on an empty remote host drew the local machine's tab strip under a
    /// session button naming the remote one.
    var visibleTabs: [TabLayout] {
        guard let session = selectedSession else {
            return tabs.filter { $0.session.host == currentHost }
        }
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

    /// Make a terminal on a host. Defaults to the machine the window is on, in
    /// the session in front there.
    func createTerminal(sessionName: String? = nil, on host: ServerHost? = nil) {
        let target = host.flatMap { self.host($0) } ?? current
        guard let target, let name = createName(typed: sessionName, joining: nil, on: target)
        else { return }
        target.createTerminal(sessionName: name)
    }

    /// A fresh session on `host` — the machine in front by default — named
    /// `session-N` for the lowest N no session there already uses.
    ///
    /// The one place that name is made. Three views each had their own
    /// `session-\(count + 1)`, and all three were wrong in the same way: a
    /// `create` is addressed by name, and the daemon *joins* a session whose
    /// name already exists rather than refusing it. Delete `session-1` of two
    /// and `count + 1` says `session-2`, which is the session still on screen —
    /// so "New Session" opened a second tab in the session you already had.
    func createSession(on host: ServerHost? = nil) {
        let target = host ?? currentHost
        guard let connection = self.host(target) else { return }
        createTerminal(sessionName: nextSessionName(on: connection), on: target)
    }

    private func nextSessionName(on host: HostConnection) -> String {
        // Exact comparison, mirroring the server's `mem.eql` — the same
        // reasoning `renameRefusal` sets out. Being case-insensitive here would
        // skip a name the daemon would have given us.
        let taken = Set(host.sessions.map(\.name))
        var index = 1
        while taken.contains("session-\(index)") { index += 1 }
        return "session-\(index)"
    }

    /// The session name a `create` should carry, or nil when it must not be
    /// sent at all. The one place that decides, so no path can bypass it.
    ///
    /// Two kinds of name reach `create`, and only one of them is this app's to
    /// refuse.
    ///
    /// A **typed** name is checked, and that is not a nicety: the server
    /// refuses a session name outside `[A-Za-z0-9._-]` with
    /// `err(invalid_name)`, and an `err` on the control channel voids *every*
    /// create outstanding on that host — the frame does not say which one
    /// failed, so `HostConnection.voidPendingCreates` cannot know. Without
    /// this, typing "My Project" into the dropdown's free-text field while a
    /// ⌘D split is in flight makes that split open as a tab instead of a pane.
    ///
    /// A name that came **from the server** is not checked. This app talks to
    /// daemons it did not ship — that is what the version-skew marker is for —
    /// and one older than the naming rule may well be holding a session called
    /// `my project`. Refusing it here would make ⌘T, the `+` button and the
    /// empty-state button all do nothing, with nothing on screen saying why:
    /// the silent no-op the check exists to prevent, turned on the user.
    ///
    /// `joining` is a *session*, and resolving it back to a name here is the
    /// residual issue #37 names ("`create` takes a name rather than an ID").
    /// See docs/CLIENT.md, "A session is addressed by name on the way in".
    private func createName(
        typed: String?, joining: SessionRef?, on host: HostConnection
    ) -> String? {
        if let typed {
            let name = SessionName.normalized(typed)
            return SessionName.isValid(name) ? name : nil
        }
        if let joining, let match = host.sessions.first(where: { $0.id == joining.session }) {
            return match.name
        }
        return frontSessionName(on: host) ?? CreateBody.defaultSessionName
    }

    /// What the dropdown offers for what has been typed into its filter field.
    ///
    /// In the store because it is two decisions that have to agree — whether
    /// Enter creates, and what is shown when it does not — and a view cannot
    /// be asked either question. Both used to live in `SessionMenu`, where a
    /// regression in either was invisible: a Create row whose Enter does
    /// nothing is exactly the silent no-op the notice was added to kill.
    func filterOffer(_ typed: String) -> FilterOffer {
        let name = SessionName.normalized(typed)
        guard !name.isEmpty else { return .nothing }
        if let refusal = SessionNameRefusal.of(name) { return .refused(refusal) }
        guard current != nil else { return .nothing }
        // Checked against *every* host's sessions, not just the one in front.
        // The rows below list them all, so a name that matches a session on
        // another machine is one you can switch to — offering "Create" for it
        // as well meant Enter silently made a second, local session with the
        // same name instead of going where the visible row pointed.
        let exists = hosts.contains { host in
            host.sessions.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        return exists ? .nothing : .create(name)
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

    /// Stop drawing a terminal without asking the server to end it.
    ///
    /// The client half of `kill`, and the whole of what a session delete needs
    /// locally: the connection goes, and the reconcile is told not to open a
    /// tab for this terminal again while the server is still listing it. The
    /// *ending* is the server's, because `delete_session` cascades — sending a
    /// `kill` per terminal on top of it would be a second SIGHUP for every one
    /// of them and, on the way, a set of killed terminals inside a session the
    /// server might still have refused to delete.
    private func forget(_ ref: TerminalRef) {
        closing.insert(ref)
        closeController(ref)
    }

    // MARK: - Renaming and deleting sessions
    //
    // Both are session-scoped and neither has a positional reply: the server
    // answers a success with the `sessions_changed` broadcast every client
    // re-lists on, and a failure with an `err` on the control channel. So
    // nothing here is optimistic about the *name*. What is not optional is the
    // client-side name check: an `err` voids every create in flight on that
    // host, so a name the server would refuse is worth never sending.

    /// Why renaming `ref` to what has been typed would not go out, or nil when
    /// it would.
    ///
    /// The whole rule, in one place, so the field's colour and Enter's
    /// behaviour cannot disagree — they did: the field validated the raw text
    /// and the commit sent a trimmed one, so `work ` painted amber, showed the
    /// "use these characters" tooltip, and then renamed successfully.
    func renameRefusal(_ ref: SessionRef, to typed: String) -> SessionNameRefusal? {
        let name = SessionName.normalized(typed)
        if let refusal = SessionNameRefusal.of(name) { return refusal }
        // The duplicate check the create path has always had, and rename needs
        // more: you rename *towards* names you already use. Without it the
        // server answers `name_in_use`, and that `err` on the control channel
        // voids every create in flight on the host — so a rename that quietly
        // did nothing also turned somebody's in-flight ⌘D into a whole new tab
        // that stole the selection.
        //
        // Scoped to `ref.host`: names are unique per daemon, and refusing a
        // local rename because a remote machine uses that name would be
        // inventing a rule the server does not have. Exact, not
        // case-insensitive, because `Server.renameSession` compares with
        // `mem.eql` — being stricter here would refuse a rename the server
        // accepts. (`filterOffer` is case-insensitive on purpose: it is
        // choosing between "switch to the row you can see" and "make a second
        // one", which is a different question.)
        let taken =
            host(ref.host)?.sessions.contains { $0.id != ref.session && $0.name == name } ?? false
        return taken ? .inUse : nil
    }

    /// Rename a session. The server is the authority; this refuses first.
    ///
    /// Deliberately changes nothing locally. Every place a session name is
    /// drawn — the tab strip, the session button, the dropdown — reads
    /// `host.sessions` by id, so the `list` behind `sessions_changed` moves
    /// all of them at once, and a rename the server refused simply is not
    /// there on the next one. `SessionRef` keys on the id, so no tab moves:
    /// that is the stability property issue #37 asks to audit, and
    /// `SessionLifecycleTests` pins it.
    ///
    /// Returns whether the request left this process, so the field that sent
    /// it knows whether to close.
    @discardableResult
    func renameSession(_ ref: SessionRef, to typed: String) -> Bool {
        guard renameRefusal(ref, to: typed) == nil else { return false }
        guard let host = host(ref.host) else { return false }
        return host.renameSession(ref.session, to: SessionName.normalized(typed))
    }

    /// File ▸ Rename Session…: open the dropdown with that row already a field.
    ///
    /// The field *is* the row, so there is no second place to put it and no
    /// sheet to raise. Nothing is armed for a session that is not there —
    /// `SessionMenu` would find no row matching it, focus nothing, and leave a
    /// dropdown with a dead keyboard.
    func requestRenameSession(_ ref: SessionRef) {
        guard session(ref) != nil else { return }
        pendingRename = ref
        sessionMenuOpen = true
    }

    /// Whether deleting `ref` is something this window can actually carry out.
    ///
    /// The connection matters as much as the session existing. `controlClosed`
    /// keeps `sessions` through a reconnect — deliberately, they are the last
    /// thing the machine said it had — so every row in the dropdown still
    /// looks live while nothing can be sent. Offering Delete there asked a
    /// person to confirm something irreversible that could not happen.
    func canDeleteSession(_ ref: SessionRef) -> Bool {
        session(ref) != nil && host(ref.host)?.canSend == true
    }

    /// Ask for a session to be deleted. Fills in the dialog; destroys nothing.
    ///
    /// Nothing pends for a session that is not there or cannot be reached:
    /// there would be no name and no count to put in the sentence, and the
    /// dialog would be promising something it cannot do.
    func requestDeleteSession(_ ref: SessionRef) {
        guard canDeleteSession(ref), let summary = session(ref) else { return }
        pendingDestruction = .deleteSession(
            ref, name: summary.name, terminalCount: summary.terminals.count)
    }

    /// Ask the server to delete a session, and take its tabs if it was asked.
    ///
    /// **The request goes first, and the window is only torn down if it left.**
    /// The other order destroyed a window's worth of state on the strength of
    /// a `try?`: `HostConnection` sends on a control connection that is nil
    /// through every reconnect, the dropdown still lists the session because
    /// `controlClosed` keeps `sessions` on purpose, and so a confirmed delete
    /// dropped the tabs, pinned the terminals invisible for the life of the
    /// process (`closing` is only ever intersected with what is *live*, and
    /// they stayed live), and left the next click on that session making a
    /// third terminal — under a dialog that had just said "This cannot be
    /// undone."
    ///
    /// Re-checked here rather than trusting the value the dialog was built
    /// from: the session's last terminal can exit between the right-click and
    /// the confirm, and `delete_session` for a session the server has already
    /// retired is answered `no_such_session` — an `err` on the control
    /// channel, which voids every create in flight on that host.
    ///
    /// The tabs go immediately once it *has* been sent, rather than on the
    /// server's word, because deleting is SIGHUP → child exit → retirement on
    /// the maintenance tick: a quarter of a second at best, and longer for a
    /// child that is slow to go. Leaving the panes up for that would draw live
    /// surfaces attached to terminals we have just asked to end. `forget` is
    /// what stops the reconcile putting the tabs straight back while the
    /// server is still listing them.
    private func deleteSession(_ ref: SessionRef) {
        guard let host = host(ref.host), session(ref) != nil else { return }
        guard host.deleteSession(ref.session) else { return }

        let wasInFront = selectedTab?.session
        for tab in tabs where tab.session == ref {
            for pane in tab.panes { forget(pane.terminal) }
        }
        tabs.removeAll { $0.session == ref }
        repairSelection(preferring: wasInFront)
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
            let host = host(tab.session.host),
            // Through `createName` like every other create, rather than
            // resolving the name here: this was the one path that reached
            // `HostConnection.createTerminal` directly, so it had no gate at
            // all and no way to grow one.
            let name = createName(typed: nil, joining: tab.session, on: host)
        else { return }
        // The pane appears when the server answers with a terminal id. Over a
        // unix socket that is one round trip; a placeholder pane would be more
        // machinery than the wait is worth. Over SSH it is a round trip on an
        // already-open channel, which is the same order of magnitude.
        pendingSplits.append(
            PendingSplit(host: host.host, tab: tabID, pane: paneID, direction: direction))
        host.createTerminal(sessionName: name)
    }

    /// Close one pane. The last pane in a tab closes the tab.
    ///
    /// Returns whether there was a pane there to close. ⌘W's answer to AppKit
    /// is "did I handle this", and a stale pane id is a no — without the
    /// result `closeSurfacePane` reported success for a pane it never touched,
    /// and the keystroke vanished into nothing at all.
    @discardableResult
    func closePane(_ paneID: UUID, in tabID: TabLayout.ID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
            let pane = tabs[index].root.pane(paneID)
        else { return false }

        kill(pane.terminal)

        // Take it out of the layout now rather than waiting for the server to
        // confirm: the connection is already closed, so the pane would render
        // a dead terminal in the meantime.
        if let root = tabs[index].root.removing(paneID) {
            // The tree's topology changed, so the surviving panes' frames do
            // too. `SplitPair` computes those frames from ratio and topology
            // alone, so animating the mutation animates the geometry.
            Motion.splits.run {
                tabs[index].root = root
                tabs[index].repairFocus()
            }
        } else {
            let wasInFront = selectedTab?.session
            tabs.remove(at: index)
            repairSelection(preferring: wasInFront)
        }
        return true
    }

    // MARK: - Ordering
    //
    // Tab order is this window's, and nothing else's. The server has no
    // opinion about it -- a session is a set of terminals, not a list -- and
    // splits are already per-window state, so a reorder never leaves the
    // process. Nor does it survive one: `reconcileTabs` builds the list from
    // each host's `session_list`, so a relaunch is back to the server's order.
    // Issue #38 argues that is right -- layout is per-window client state, and
    // there is only one window -- and persisting it is a feature, not polish.

    /// Move `id` into the slot before `target`, or to the end of its session's
    /// run when `target` is nil.
    ///
    /// Refuses a move across two sessions. The strip only ever draws one
    /// session's tabs (`visibleTabs`), so a cross-session drop is not something
    /// the UI can produce; refusing it here means the model cannot be talked
    /// into an order the strip could not show.
    ///
    /// Selection is deliberately untouched *here*. Reordering is not switching,
    /// and keeping the two apart is what lets the strip's own select button
    /// decide: it fires on the mouse-up that ends a drag, so a dragged tab does
    /// come to the front, the way it does in every tabbed app — but that is the
    /// button's doing and can change without touching this.
    func moveTab(_ id: TabLayout.ID, before target: TabLayout.ID?) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let session = tabs[from].session

        // Where it lands, as an index into the array *before* the removal.
        let destination: Int
        if let target {
            guard let to = tabs.firstIndex(where: { $0.id == target }) else { return }
            guard tabs[to].session == session else { return }
            destination = to
        } else {
            // The end of this session's tabs rather than the end of the array:
            // `visibleTabs` filters `tabs` and keeps its order, so this is the
            // end of the strip, and another session's tabs stay where they are.
            guard let last = tabs.lastIndex(where: { $0.session == session }) else { return }
            destination = last + 1
        }

        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: from < destination ? destination - 1 : destination)
    }

    /// A drop of `id` onto `target`'s slot: the dragged tab takes that slot and
    /// the others close up around it.
    ///
    /// Which side of `target` that is depends on which way the tab travelled,
    /// which is why this is not `moveTab(_:before:)` with the drop target
    /// passed straight through: dragging left, "onto" means before; dragging
    /// right, it means after, or the tab would land one slot short of where it
    /// was dropped.
    func moveTab(_ id: TabLayout.ID, onto target: TabLayout.ID) {
        guard id != target,
            let from = tabs.firstIndex(where: { $0.id == id }),
            let to = tabs.firstIndex(where: { $0.id == target })
        else { return }
        // Checked here as well as in `moveTab(_:before:)`, not instead of it.
        // Travelling right the call below passes the tab *after* the target,
        // and the last tab of a session has none — so the move would arrive as
        // `before: nil`, which is a perfectly legal within-session append, and
        // a cross-session drop would go through.
        guard tabs[from].session == tabs[to].session else { return }
        guard from < to else { return moveTab(id, before: target) }
        // Travelling right: land after the target, which is "before whatever
        // follows it in the same session" — the next tab in the *array* may
        // belong to another session, and `moveTab(_:before:)` would refuse it.
        let next = tabs[(to + 1)...].first { $0.session == tabs[to].session }?.id
        moveTab(id, before: next)
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
        Motion.splits.run {
            tabs[index].zoomed = tabs[index].zoomed == paneID ? nil : paneID
        }
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

    // MARK: - The ⌘W policy
    //
    // Closing lives here rather than in `TerminalPane` so it can be tested
    // without a window: the surface's delegate is one line over this, and this
    // file is in the test target.

    /// ⌘W, as issue #41 specifies it.
    ///
    /// True: a pane was closed here, and the window stays. False: this is the
    /// last pane of the last tab, so closing it *is* closing the window — the
    /// caller lets `performClose` fall through to `NSWindow`.
    ///
    /// `tabs.count`, not `visibleTabs.count`. A window whose front session has
    /// one tab may still be holding tabs on another session, and closing the
    /// window would take those with it; `repairSelection` moves to them
    /// instead, which is exactly the behaviour its own doc comment describes.
    func closeSurfacePane(_ paneID: UUID, in tabID: TabLayout.ID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        guard tabs.count > 1 || tab.isSplit else { return false }
        // Forwarded, not assumed. A pane id the layout no longer holds is not
        // something this closed, and telling AppKit otherwise swallowed the
        // keystroke entirely.
        return closePane(paneID, in: tabID)
    }

    /// What the caller still has to do after asking for a tab to close.
    ///
    /// The window half cannot live in the store — there is no window here —
    /// but the *decision* can, which is the only part worth a test.
    enum CloseTabOutcome: Equatable {
        /// Closed, or there was nothing there. Nothing further to do.
        case closed
        /// The dialog is up. `confirmPendingDestruction` finishes it.
        case confirming
        /// This was the window's last tab, so closing it is closing the
        /// window. The caller sends `performClose:`; nothing was killed.
        case closeWindow
    }

    /// ⇧⌘W and the tab strip's ✕.
    ///
    /// Three outcomes, and the ordering between them is the point:
    ///
    /// *The window's last tab closes the window*, exactly as ⌘W on its last
    /// pane does, and like ⌘W it kills nothing — closing a window here has
    /// always meant detaching, which is what the empty state promises in as
    /// many words ("Sessions keep running after you close this window"). Two
    /// chords one modifier apart used to disagree on both halves of that: ⌘W
    /// closed the window and left the shell running, ⇧⌘W hung the shell up and
    /// left an empty window behind. It is also what every tabbed Mac app does
    /// with ⇧⌘W, and it is why this case needs no confirmation: nothing is
    /// destroyed.
    ///
    /// *A tab with more than one pane asks first*, because `closeTab` really
    /// does hang up every terminal in it.
    ///
    /// *One pane closes outright* — no shipping terminal confirms a single
    /// close, and the one thing that would justify it, a foreground process
    /// still running, is not something we can detect
    /// (`TerminalSummary.command` is the child's argv[0], not the foreground
    /// job).
    @discardableResult
    func requestCloseTab(_ tabID: TabLayout.ID) -> CloseTabOutcome {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return .closed }
        if tabs.count == 1 {
            return .closeWindow
        }
        if tab.panes.count > 1 {
            pendingDestruction = .closeTab(tabID, paneCount: tab.panes.count)
            return .confirming
        }
        closeTab(tabID)
        return .closed
    }

    /// Carry out what the dialog is asking about.
    ///
    /// The value is a parameter and not only a stored slot because SwiftUI
    /// writes `isPresented = false` as the dialog dismisses, and that write is
    /// what clears `pendingDestruction` — a confirm button that read the slot
    /// back could find it already empty. The view hands back the value the
    /// dialog was built from.
    func confirmPendingDestruction(_ pending: PendingDestruction) {
        pendingDestruction = nil
        switch pending {
        case .closeTab(let tabID, _): closeTab(tabID)
        case .deleteSession(let ref, _, _): deleteSession(ref)
        }
    }

    func confirmPendingDestruction() {
        guard let pending = pendingDestruction else { return }
        confirmPendingDestruction(pending)
    }

    func cancelPendingDestruction() {
        pendingDestruction = nil
    }

    // MARK: - Tab navigation
    //
    // Keyboard tab switching is store state, so ⇧⌘] and ⌘1 are testable
    // without a menu bar. All of it is scoped to `visibleTabs`: the strip only
    // ever shows one session's tabs, and a chord must not jump the window to
    // another machine.

    func selectNextTab() { selectTab(offsetBy: 1) }
    func selectPreviousTab() { selectTab(offsetBy: -1) }

    private func selectTab(offsetBy offset: Int) {
        let tabs = visibleTabs
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID })
        else { return }
        // Wrapping, the way Terminal.app's ⇧⌘] does at either end.
        selectedTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    /// ⌘1 … ⌘9, one-based into the session in front.
    ///
    /// Nine is the *last* tab rather than the ninth — the convention iTerm,
    /// Ghostty and every browser share. Anything else out of range does
    /// nothing.
    func selectTab(at index: Int) {
        let tabs = visibleTabs
        guard !tabs.isEmpty else { return }
        if index == Self.lastTabIndex {
            selectedTabID = tabs.last?.id
            return
        }
        guard index >= 1, index <= tabs.count else { return }
        selectedTabID = tabs[index - 1].id
    }

    /// The one-based index ⌘9 occupies, which means "last".
    static let lastTabIndex = 9

    /// Whether ⌘`index` would go anywhere, so the menu item can tell the truth.
    ///
    /// Honesty, not safety. A disabled item still consumes its key equivalent
    /// — `performKeyEquivalent` reports the chord as handled and simply does
    /// not fire the action — so ⌘5 with two tabs never reaches the surface
    /// either way. The reason to grey it is that an enabled item which does
    /// nothing is a lie about what the app can do.
    func canSelectTab(at index: Int) -> Bool {
        let tabs = visibleTabs
        guard !tabs.isEmpty else { return false }
        if index == Self.lastTabIndex { return true }
        return index >= 1 && index <= tabs.count
    }

    /// ⌘K. The tooltip on the session button has promised this since the
    /// chrome landed.
    ///
    /// Focus is not restored here: ContentView watches `sessionMenuOpen` and
    /// calls `focusTerminal` for *every* way the menu closes — Escape, a click
    /// away, picking a session — and one owner of that rule is the point.
    func toggleSessionMenu() {
        sessionMenuOpen.toggle()
    }

    // MARK: - Focus

    /// Bumped whenever the terminal should take the keyboard back.
    ///
    /// `TerminalSurface.updateNSView` re-asserts first responder whenever
    /// SwiftUI re-evaluates it, so a counter read by `TerminalPane`'s body is
    /// all it takes to make that happen on demand — which is what closing the
    /// session menu needs: the menu's filter field held focus, and nothing in
    /// the split tree changed when the overlay went away.
    ///
    /// Only the counter is tested. Everything between it and AppKit's first
    /// responder — SwiftUI's decision to re-evaluate, `updateNSView`,
    /// `makeFirstResponder` — needs a running app, and was **verified by
    /// hand**, not by this suite.
    private(set) var focusGeneration = 0

    func focusTerminal() { focusGeneration &+= 1 }

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
        Motion.splits.run {
            tabs[tab].root = tabs[tab].root.splitting(
                pending.pane, with: pane, direction: pending.direction)
            tabs[tab].focused = pane.id
        }
        // Outside the animation on purpose. A split can land in a tab that is
        // not in front, and bringing it forward is a *tab switch* — the one
        // thing in this app that must not animate.
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

        if let restore = pendingRestore, let connection = host(restore.host),
            connection.status.isConnected
        {
            // The machine has answered — `.connected` is set on the
            // `session_list` immediately before this runs — so its list is
            // authoritative and this is the moment to land or give up. Either
            // way the restore is spent: a later list is a machine that has
            // changed since, not a launch.
            pendingRestore = nil
            let target =
                connection.sessions.first { $0.name == restore.name }
                ?? connection.sessions.first
            if let target,
                let tab = tabs.first(where: {
                    $0.session == SessionRef(host: restore.host, session: target.id)
                })
            {
                selectedTabID = tab.id
            }
        }

        repairSelection(preferring: wasInFront)
        dismissStaleDestruction()

        if let direction = pendingLaunchSplit, selectedTab != nil {
            pendingLaunchSplit = nil
            split(direction)
        }
    }

    /// Take down a confirmation whose subject has gone.
    ///
    /// Both terminals of a split can exit on their own while the dialog is
    /// up — and then it is asking about a tab that is no longer on screen.
    /// Confirming a stale one was already harmless (`closeTab` guards on
    /// `firstIndex`, and tab ids are fresh UUIDs so nothing can inherit one);
    /// this is about the dialog telling the truth while it is being read.
    private func dismissStaleDestruction() {
        switch pendingDestruction {
        case .closeTab(let tabID, _):
            if !tabs.contains(where: { $0.id == tabID }) { pendingDestruction = nil }
        // A session whose last terminal exits on its own while the dialog is
        // up is a session the server has already retired. Asking about it is
        // asking about nothing, and confirming would send a `delete_session`
        // the daemon answers `no_such_session` -- an `err` on the control
        // channel, which voids every create in flight on that host.
        case .deleteSession(let ref, _, _):
            if session(ref) == nil { pendingDestruction = nil }
        case nil:
            break
        }
    }

    /// Put the selection somewhere sensible after the tab list changed.
    ///
    /// The only place `selectedTabID` is repaired. `closePane` and `closeTab`
    /// used to do their own `tabs.first?.id`, which is how closing the last tab
    /// of a remote session teleported the window to the local machine: the
    /// session button changed host and the strip's contents changed with it.
    /// Prefer the session that was in front, then any tab on the machine you
    /// are on.
    ///
    /// `wanted` is always a session on `currentHost` — every caller reads it
    /// off a tab that was in front, and `switchHost` passes one keyed to the
    /// machine it has just moved to — so the second clause is a widening of the
    /// first rather than a second answer.
    private func repairSelection(preferring wanted: SessionRef?) {
        if let id = selectedTabID, tabs.contains(where: { $0.id == id }) { return }
        selectedTabID =
            tabs.first { $0.session == wanted }?.id
            ?? tabs.first { $0.session.host == currentHost }?.id
        // No `?? tabs.first?.id`. A machine with nothing on it is a place the
        // window can be now — Switch Host puts you there — and stealing another
        // machine's tab would move the toolbar, the strip and the next ⌘T
        // somewhere nobody asked to go, on the strength of an unrelated host's
        // list having changed.
    }

    // MARK: - Where the window is
    //
    // Selecting a tab is also how the window moves between machines, so every
    // write to `selectedTabID` lands here. Which makes this the one place that
    // decides what "you are on this machine, in this session" means — a view
    // cannot be asked either half.

    private func selectionChanged() {
        // A nil selection changes nothing. It is the resting state of a machine
        // with nothing on it, and it arrives on the way through `switchHost`
        // and every repair, neither of which is a person leaving a host.
        guard let tab = selectedTab else { return }
        currentHost = tab.session.host
        lastSession[currentHost] = tab.session
        // Somebody has chosen a tab, so whatever the last launch was on is no
        // longer what this window is about.
        pendingRestore = nil
        rememberFrontSession(tab.session)
    }

    /// Write the front session through, if it is not already what is on disk.
    ///
    /// Write-through rather than at exit: there is no termination hook in this
    /// app — no app delegate, no `willTerminate`, no `scenePhase` — and a write
    /// at exit is a write that a force-quit or a crash loses, which is exactly
    /// the run whose session you would most like back.
    ///
    /// A session the host has not listed yet is not written. There is no name
    /// to write, and the id is no use across a restart.
    private func rememberFrontSession(_ ref: SessionRef) {
        guard let name = session(ref)?.name else { return }
        let front = FrontSession(host: ref.host, name: name)
        guard front != writtenFront else { return }
        writtenFront = front
        FrontSessionStore.save(front, to: defaults)
    }

    // MARK: - Per-terminal connections

    /// The controller for a terminal, creating and attaching one if needed.
    func controller(for ref: TerminalRef, size: SurfaceSize) -> TerminalController? {
        host(ref.host)?.controller(for: ref.terminal, size: size)
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

/// Something destructive, waiting to be confirmed.
///
/// The wording lives here rather than in the view so it is one thing to read
/// and one thing to test: what the dialog says is part of the policy, not a
/// detail of how it is drawn.
///
/// A value, not a closure, for a second reason too: what a session *held* has
/// to be captured when the question is asked. A `sessions_changed` arriving
/// while the dialog is up would otherwise change the sentence underneath the
/// person reading it, or empty it.
enum PendingDestruction: Equatable {
    /// A tab with more than one pane. `paneCount` is what the message counts.
    case closeTab(TabLayout.ID, paneCount: Int)
    /// A session, and what it held when the question was asked.
    case deleteSession(SessionRef, name: String, terminalCount: Int)

    var title: String {
        switch self {
        case .closeTab: "Close this tab?"
        // Names the session. The dropdown row that was right-clicked is gone
        // by the time this is read, and a destructive dialog that does not say
        // what it is about is one a person has to guess at.
        case .deleteSession(_, let name, _): "Delete session \u{201C}\(name)\u{201D}?"
        }
    }

    var message: String {
        switch self {
        case .closeTab(_, let paneCount):
            "Its \(Self.terminals(paneCount)) will be closed. This cannot be undone."
        // An empty session is the case issue #37 opens with -- every terminal
        // killed, and no way to be rid of what is left -- so it has to read as
        // a sentence rather than as "Its 0 terminals will be closed."
        case .deleteSession(_, _, 0):
            "It has no terminals left. This cannot be undone."
        case .deleteSession(_, _, let count):
            "Its \(Self.terminals(count)) will be closed. This cannot be undone."
        }
    }

    /// "1 terminal", "3 terminals". A dialog that says "1 terminals" is one a
    /// person stops trusting the rest of.
    private static func terminals(_ count: Int) -> String {
        count == 1 ? "1 terminal" : "\(count) terminals"
    }

    /// The destructive button's title. Named after what it does, not "OK":
    /// the one thing a confirmation must not be is ambiguous.
    var confirmTitle: String {
        switch self {
        case .closeTab: "Close Tab"
        case .deleteSession: "Delete Session"
        }
    }
}

/// Why the server would refuse a session name, phrased for the person typing
/// it.
///
/// Here rather than in `SessionMenu` because it is policy, not decoration: the
/// dropdown's "Filter or create\u{2026}" field is the one place free text reaches
/// `create`, and the daemon answers `err(invalid_name)` for anything outside
/// `[A-Za-z0-9._-]`. Before this, a space in that field made Enter do nothing
/// at all -- no Create row, no match to fall through to, and no reason on
/// screen.
///
/// Derived from ``SessionName/isValid(_:)`` rather than re-deciding: `of` is
/// nil for exactly the names that one accepts, so the two cannot drift into
/// disagreeing about which names are creatable.
enum SessionNameRefusal: Equatable {
    case empty
    case tooLong
    case badCharacters
    /// Another session on that machine already has this name. Not something
    /// ``of(_:)`` can see — it is about one name — so only `renameRefusal` and
    /// `filterOffer`, which know which sessions exist, produce it.
    case inUse

    static func of(_ name: String) -> SessionNameRefusal? {
        guard !SessionName.isValid(name) else { return nil }
        if name.isEmpty { return .empty }
        if name.utf8.count > SessionName.maxLength { return .tooLong }
        return .badCharacters
    }

    /// Short, because it is drawn in a dropdown row in place of the Create
    /// row and SwiftUI truncates rather than wraps: `MenuMetrics.titleWidth`
    /// is the budget, and `SessionLifecycleTests` measures every sentence here
    /// against it. Two of these did not fit, and the one people reach by
    /// typing a space lost the half that carried the meaning. It says what is
    /// allowed rather than what was wrong -- the field is right there with the
    /// offending text still in it.
    ///
    /// "bytes" and "A-Z a-z" are literal on purpose. The limit really is 64
    /// *bytes*, so a name of thirty emoji is refused by this message and
    /// telling that person to "shorten" it would be advice that cannot work;
    /// and the character class really is ASCII, so "letters" would promise an
    /// accented one that the server refuses.
    var message: String {
        switch self {
        case .empty: "Type a name"
        case .tooLong: "Up to \(SessionName.maxLength) bytes"
        case .badCharacters: "Use A-Za-z0-9 . _ -"
        case .inUse: "That name is taken"
        }
    }
}

/// What the dropdown's "Filter or create…" field can offer for what is in it.
enum FilterOffer: Equatable {
    /// Offer to create this — already normalized, so it is exactly what will
    /// be sent.
    case create(String)
    /// Say why it cannot be, where the Create row would have gone.
    case refused(SessionNameRefusal)
    /// Neither: nothing has been typed, or it names a session already on
    /// screen that you can simply switch to.
    case nothing
}

extension SessionName {
    /// What a typed name actually becomes.
    ///
    /// The ends only. Surrounding whitespace is a typing artefact rather than
    /// something somebody means, and the server refuses it — so trimming is
    /// what keeps "the field says why" and "Enter works" agreeing about
    /// `work `, which they did not: one validated the raw text and the other
    /// sent a trimmed one. An *inner* space is a real character in a name the
    /// server will not take, and quietly deleting it would make a session
    /// under a name nobody asked for.
    static func normalized(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// The session that was in front, as it survives a relaunch: the machine, and
/// the session's *name*.
///
/// Not its id. A daemon's `next_session_id` is an in-memory counter
/// (src/daemon/Server.zig), so a machine that rebooted renumbers everything it
/// still has and an id restored across launches points at whatever now happens
/// to hold it. A name is what a session is called by the people using it, and
/// docs/CLIENT.md's governing rule already says a session is addressed by name
/// on the way in.
struct FrontSession: Codable, Equatable {
    var host: ServerHost
    var name: String
}

/// Where that session is written. One key, one small blob, read once at init.
enum FrontSessionStore {
    static let key = "frontSession"

    static func load(_ defaults: HostDefaults = UserDefaults.standard) -> FrontSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FrontSession.self, from: data)
    }

    static func save(_ front: FrontSession, to defaults: HostDefaults = UserDefaults.standard) {
        guard let data = try? JSONEncoder().encode(front) else { return }
        defaults.set(data, forKey: key)
    }
}
