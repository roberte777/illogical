//  CurrentHostTests.swift
//  Which machine the window is on, now that it is a thing the store holds.
//
//  It used to be read off the front tab, and that made two things impossible to
//  say: that you are on a machine with nothing on it, and that you are still on
//  a machine whose connection has gone. Both are ordinary — Switch Host puts
//  you on the first, a laptop lid puts you on the second — so nearly everything
//  below is about a window with no tab in front.
//
//  Two drive styles, and the choice is about what is being asserted. Selection,
//  repair and restore are driven without a socket: a `HostConnection` publishes
//  its lists as plain properties, so setting them and calling `reconcileTabs()`
//  is the same path a `session_list` frame takes. What a `create` *carries*
//  cannot be driven that way — `Connection.send` on a nil control connection is
//  silently nothing, which is indistinguishable from a correct refusal — so
//  those run against a `RecordingServer`.

import Foundation
import IllogicalProtocol
import XCTest

@MainActor
final class CurrentHostTests: XCTestCase {
    private static let local = ServerHost.local(socketPath: "/tmp/illogical-current.sock")
    private static let remote = ServerHost.ssh(destination: "build-box")

    /// Somewhere in memory to read and write, and a count of the writes.
    ///
    /// The count is the only way to tell "written through as it changes" from
    /// "written on every selection": a store that saved unconditionally passes
    /// every assertion about the *value*, and would rewrite the same session on
    /// every ⌘1 for the life of the window.
    private final class InMemoryDefaults: HostDefaults {
        private var values: [String: Data] = [:]
        private(set) var writes: [String: Int] = [:]
        func data(forKey defaultName: String) -> Data? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) {
            values[defaultName] = value as? Data
            writes[defaultName, default: 0] += 1
        }
    }

    private typealias Listing = (id: UInt64, name: String, terminals: [UInt64])

    /// A store with the hosts named and nothing on any of them, dialling
    /// nothing: the launcher is injected for the same reason the defaults are,
    /// since a `.local` host that reached `connect()` with the real one would
    /// start a daemon.
    private func emptyStore(
        _ hosts: [ServerHost] = [local], defaults: InMemoryDefaults = InMemoryDefaults()
    ) -> SessionStore {
        SessionStore(
            hosts: hosts, defaults: defaults, launcher: RecordingLauncher(.succeedSilently))
    }

    /// What a `session_list` frame does, without a socket.
    ///
    /// The status is part of it. `HostConnection` sets `.connected` on the list
    /// and calls `onListChanged` on the next line, and the launch restore waits
    /// on exactly that — so a helper that only assigned the arrays would be
    /// driving a state the wire cannot produce.
    ///
    /// `terminalOrder` names the terminals in the order the host reports them,
    /// and it is what lets a fixture tell "the host's first *session*" from
    /// "the host's first *tab*". `reconcileTabs` appends tabs in
    /// `host.terminals` order, so with the default — every session's terminals,
    /// in session order — the two answers always agree, and an assertion meant
    /// to pin a lookup by session passes just as well under code that took the
    /// first tab it saw. Two of the tests below were exactly that.
    ///
    /// It reorders within one rule, and the rule is the wire's: `terminals` is
    /// ascending by id, always. `Server.listInto` walks an insertion-ordered
    /// map fed by a monotonic `next_terminal_id`, retirement is an
    /// `orderedRemove`, and `HostConnection` takes the list wholesale — so a
    /// descending fixture is a state no daemon can produce. The way to put a
    /// later session's tab first is therefore to give the *earlier* session the
    /// later terminal, which is what a session outliving its original terminal
    /// looks like.
    private func list(
        _ store: SessionStore, host: ServerHost = local, _ sessions: [Listing],
        terminalOrder: [UInt64]? = nil
    ) {
        guard let connection = store.host(host) else { return XCTFail("no such host") }
        connection.sessions = sessions.map {
            SessionSummary(id: $0.id, name: $0.name, terminals: $0.terminals)
        }
        let listed = sessions.flatMap { session in
            session.terminals.map { terminal($0, session: session.id) }
        }
        if let terminalOrder {
            // Reordered, never re-invented: a fixture that named a terminal no
            // session holds would be driving a list the wire cannot produce,
            // and the reconcile would answer it perfectly reasonably.
            //
            // Compared as contents rather than as a count. `[2, 2]` names two
            // terminals and the sessions hold two, so counting passed it — and
            // handed the reconcile the same terminal twice, which is a listing
            // no daemon can produce either.
            connection.terminals = terminalOrder.compactMap { id in listed.first { $0.id == id } }
            XCTAssertEqual(
                terminalOrder.sorted(), listed.map(\.id).sorted(),
                "terminalOrder does not name exactly the terminals the sessions hold")
        } else {
            connection.terminals = listed
        }
        XCTAssertEqual(
            connection.terminals.map(\.id), connection.terminals.map(\.id).sorted(),
            "a daemon lists terminals in ascending id order; this fixture does not")
        connection.setStatusForTesting(.connected)
        store.reconcileTabs()
    }

    private func terminal(_ id: UInt64, session: UInt64) -> TerminalSummary {
        TerminalSummary(
            id: id, session: session, name: "t\(id)", command: "/bin/zsh", cwd: "/",
            cols: 80, rows: 24, residency: .live, attached: 0, ptyReadIdleNanoseconds: 0)
    }

    /// The tab holding a given terminal on a given machine.
    private func tab(
        _ store: SessionStore, _ terminal: UInt64, on host: ServerHost = local
    ) throws -> TabLayout {
        try XCTUnwrap(
            store.tabs.first {
                $0.panes.contains { $0.terminal == TerminalRef(host: host, terminal: terminal) }
            }, "no tab for terminal \(terminal) on \(host.displayName)")
    }

    // MARK: - Where the window is

    /// Selecting a tab is also how the window moves between machines. It is the
    /// one funnel, so this is what keeps the toolbar, the strip and the next ⌘T
    /// agreeing about where they are.
    func testSelectingATabMovesTheCurrentHost() throws {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "here", [1])])
        list(store, host: Self.remote, [(1, "there", [1])])

        store.selectedTabID = try tab(store, 1, on: Self.remote).id
        XCTAssertEqual(store.currentHost, Self.remote)
        XCTAssertEqual(store.current?.host, Self.remote)
        XCTAssertEqual(store.selectedSession?.host, Self.remote)

        store.selectedTabID = try tab(store, 1).id
        XCTAssertEqual(store.currentHost, Self.local)
    }

    /// Going back to a machine lands where you left it. Without the memory,
    /// coming back to a machine you had four sessions on always meant its
    /// first one, which is not where anybody was working.
    func testSwitchHostLandsOnTheSessionYouLeft() throws {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "here", [1])])
        list(store, host: Self.remote, [(1, "a", [1]), (2, "b", [2, 3])])

        // The second tab of the second session, so that neither "the first
        // tab" nor "the first session" passes this by accident.
        store.selectedTabID = try tab(store, 3, on: Self.remote).id
        store.switchHost(Self.local)
        XCTAssertEqual(store.currentHost, Self.local)

        store.switchHost(Self.remote)
        XCTAssertEqual(store.selectedSession?.session, 2, "it went back to that machine's first")
        XCTAssertEqual(store.selectedTabID, try tab(store, 2, on: Self.remote).id)

        // ...and asking for the machine you are already on is not a move. Both
        // surfaces draw that machine — checked, and greyed because of this very
        // guard — and refuse it before they get here, so this is the store's
        // own re-guard behind them. The memory is of a session rather than a
        // tab, so without it this would drop you on the first tab of the
        // session you are already in.
        let third = try tab(store, 3, on: Self.remote).id
        store.selectedTabID = third
        store.switchHost(Self.remote)
        XCTAssertEqual(store.selectedTabID, third, "it moved inside the session it was in")
    }

    /// A machine this window has never been on has no memory to honour, so it
    /// opens on the first session the machine lists.
    ///
    /// The first *session*, which is only a different answer from "the first
    /// tab" when the machine's first session is not the one holding its first
    /// terminal — so it is not here. `a` has outlived its original terminal and
    /// holds a later one than `b` does, so the first tab belongs to `b`, which
    /// is where `switchHost` with its `?? connection.sessions.first` deleted
    /// lands instead.
    func testSwitchHostFallsBackToTheFirstSession() throws {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "here", [1])])
        list(store, host: Self.remote, [(1, "a", [3]), (2, "b", [2])], terminalOrder: [2, 3])
        store.selectedTabID = try tab(store, 1).id

        store.switchHost(Self.remote)

        XCTAssertEqual(
            store.selectedTabID, try tab(store, 3, on: Self.remote).id,
            "it took the machine's first tab rather than its first session")
        XCTAssertEqual(store.selectedSession?.session, 1)
    }

    /// The load-bearing one. A machine with nothing on it is somewhere the
    /// window can be — you go there to make its first terminal — and the
    /// selection must sit there through any amount of noise from elsewhere.
    ///
    /// `repairSelection` used to end `?? tabs.first?.id`, so the local
    /// machine's next list yanked the window back to the local machine: the
    /// session button changed, the strip filled with somebody else's tabs, and
    /// the ⌘T the person was about to press landed on the wrong daemon.
    func testAnEmptyCurrentHostStaysEmptyThroughAnotherHostsList() {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "here", [1])])
        list(store, host: Self.remote, [])

        store.switchHost(Self.remote)
        XCTAssertNil(store.selectedTabID)
        XCTAssertTrue(store.visibleTabs.isEmpty, "an empty machine borrowed another one's tabs")
        XCTAssertNil(store.selectedSession)

        // The local daemon says something — a `cd`, a terminal exiting, any
        // list at all — and none of it is about the machine in front.
        list(store, [(1, "here", [1, 2])])

        XCTAssertEqual(store.currentHost, Self.remote)
        XCTAssertNil(store.selectedTabID, "an unrelated host's list stole the selection")
        XCTAssertTrue(store.visibleTabs.isEmpty)
    }

    /// Forgetting the machine you are on has to leave the window somewhere, and
    /// `hosts.first` — the local daemon, the one host that cannot be removed —
    /// is the only somewhere there is.
    ///
    /// It goes there the way Switch Host does, so it lands in the session you
    /// were last in on that machine rather than on its first tab. Two sessions
    /// here for exactly that reason: with one, both behaviours look the same.
    func testRemovingTheCurrentHostFallsBackToLocal() throws {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "a", [1]), (2, "b", [2])])
        list(store, host: Self.remote, [(1, "there", [1])])
        store.selectedTabID = try tab(store, 2).id
        store.switchHost(Self.remote)

        store.removeHost(Self.remote)

        XCTAssertEqual(store.currentHost, Self.local)
        XCTAssertEqual(store.selectedSession?.session, 2, "it landed on the machine's first tab")
        XCTAssertEqual(store.selectedTabID, try tab(store, 2).id)
    }

    /// Closing the last tab on the machine you are on leaves you on that
    /// machine, with nothing on screen — the flip side of the invariant above,
    /// and the assertion the old `?? tabs.first?.id` fallback fails. It is the
    /// pin against a future revert: with that fallback back in place, closing
    /// your last local tab hands the window to whichever machine happens to
    /// have one.
    func testClosingTheCurrentHostsLastTabDoesNotJumpMachines() throws {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "here", [1])])
        list(store, host: Self.remote, [(9, "there", [9])])
        let here = try tab(store, 1).id
        store.selectedTabID = here

        // `.closed` rather than `.closeWindow`: two tabs exist window-wide, and
        // it is only the window's *last* tab that closes the window.
        XCTAssertEqual(store.requestCloseTab(here), .closed)

        XCTAssertNil(store.selectedTabID, "closing a tab moved the window to another machine")
        XCTAssertEqual(store.currentHost, Self.local)
        XCTAssertTrue(store.visibleTabs.isEmpty)

        // And the other machine saying anything at all does not change that.
        list(store, host: Self.remote, [(9, "there", [9])])
        XCTAssertNil(store.selectedTabID)
        XCTAssertEqual(store.currentHost, Self.local)
    }

    /// A machine that cannot be reached must say why. The empty screen's New
    /// Terminal button sends through `try?` on a connection that is not open,
    /// so "No terminals" there is a screen whose only button does nothing.
    func testAFailedCurrentHostSaysWhyInsteadOfNoTerminals() throws {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "here", [1])])
        list(store, host: Self.remote, [])
        store.switchHost(Self.remote)

        store.host(Self.remote)?.setStatusForTesting(
            .reconnecting(attempt: 2, detail: "build-box: Connection refused"))
        XCTAssertEqual(store.currentHostError, "build-box: Connection refused")
        // One machine down is not the window-wide screen: the local daemon is
        // still there and its Try Again would redial everything.
        XCTAssertNil(store.connectionError)

        store.host(Self.remote)?.setStatusForTesting(.connected)
        XCTAssertNil(store.currentHostError, "a working machine with no sessions is not an error")

        // And a live tab outranks a failure, for the reason ContentView puts
        // the tab first: a reconnect must not blank a window that is working.
        store.selectedTabID = try tab(store, 1).id
        store.host(Self.local)?.setStatusForTesting(.failed("No illogicald"))
        XCTAssertNil(store.currentHostError)
    }

    // MARK: - The session that comes back

    /// The machine, before anything has answered. The alternative — open on
    /// the local daemon and move once the remote list arrives — is a window
    /// that yanks itself out from under whoever is already typing in it.
    func testLaunchOpensOnTheMachineItWasLastOn() {
        let defaults = InMemoryDefaults()
        FrontSessionStore.save(FrontSession(host: Self.remote, name: "work"), to: defaults)

        let store = emptyStore([Self.local, Self.remote], defaults: defaults)

        XCTAssertEqual(store.currentHost, Self.remote)

        // And the local daemon answering — a unix socket against an ssh
        // handshake is not a close race — does not become the window. Without
        // a list here there are no tabs at all, so the two assertions below
        // hold under every implementation there is, including the one this test
        // exists to refuse: the tab that appears is exactly what a window that
        // had opened on the local machine would now be showing.
        list(store, [(1, "here", [1])])

        XCTAssertEqual(store.currentHost, Self.remote)
        XCTAssertNil(store.selectedTabID, "the window opened on whichever machine answered first")
        XCTAssertTrue(store.visibleTabs.isEmpty)
    }

    /// By name, and the id is the point of the fixture: a daemon's session ids
    /// are an in-memory counter, so the machine this window was on last week
    /// numbers "work" differently today. Landing on session 7 for a name is
    /// the whole difference between restoring a session and restoring a number.
    func testLaunchRestoresTheRememberedSessionByName() throws {
        let defaults = InMemoryDefaults()
        FrontSessionStore.save(FrontSession(host: Self.local, name: "work"), to: defaults)
        let store = emptyStore(defaults: defaults)

        list(store, [(3, "scratch", [1]), (7, "work", [2])])

        XCTAssertEqual(store.selectedTabID, try tab(store, 2).id)
        XCTAssertEqual(store.selectedSession?.session, 7, "the restore landed on a position")
    }

    /// A session deleted since the last run is not an error and not an empty
    /// window: the machine is up and has work on it, so the restore gives up
    /// and takes the first session, which is where a launch with no memory at
    /// all would have gone.
    ///
    /// Two sessions, the first of them holding the later terminal, so that "the
    /// host's first session" and "whatever tab the reconcile appended first"
    /// are different tabs. With one session — or with each session holding the
    /// terminal its position suggests — this passes with the whole restore
    /// block deleted, since `repairSelection` reaches the same tab on its own.
    func testARestoreNamingAGoneSessionFallsBackToTheHostsFirst() throws {
        let defaults = InMemoryDefaults()
        FrontSessionStore.save(FrontSession(host: Self.local, name: "work"), to: defaults)
        let store = emptyStore(defaults: defaults)

        list(store, [(3, "scratch", [4]), (5, "spare", [2])], terminalOrder: [2, 4])

        XCTAssertEqual(
            store.selectedTabID, try tab(store, 4).id,
            "the restore took the first tab rather than the machine's first session")
        XCTAssertEqual(store.selectedSession?.session, 3)
    }

    /// Anything the person selects first wins, and wins permanently. The
    /// remembered session is a guess about where somebody wants to be, and a
    /// guess that arrives late and overrides them is selection theft.
    func testAUserSelectionVoidsTheRestore() throws {
        let defaults = InMemoryDefaults()
        FrontSessionStore.save(FrontSession(host: Self.remote, name: "work"), to: defaults)
        let store = emptyStore([Self.local, Self.remote], defaults: defaults)

        // The local daemon answers first: a unix socket against an ssh
        // handshake is not a close race. The window is on build-box and
        // build-box has not spoken, so there is nothing to show yet.
        list(store, [(1, "here", [1])])
        XCTAssertNil(store.selectedTabID)

        // The person gets tired of waiting and goes to the local machine.
        store.switchHost(Self.local)
        let here = try tab(store, 1).id
        XCTAssertEqual(store.selectedTabID, here)

        // ...and now build-box answers, with the very session that was
        // remembered.
        list(store, host: Self.remote, [(7, "work", [1])])

        XCTAssertEqual(store.selectedTabID, here, "a late restore moved the window")
        XCTAssertEqual(store.currentHost, Self.local)
    }

    /// The sibling of the test above, and the one the funnel could not cover:
    /// there the switch lands on a tab, so `selectionChanged` voids the restore
    /// on its way past. Here the machine somebody switches to has nothing on
    /// it — which is the case this whole feature exists for — so nothing is
    /// selected, nothing runs, and the remembered machine finishing its
    /// handshake five seconds later used to take the window with it.
    func testSwitchingToAnEmptyMachineVoidsTheRestore() {
        let defaults = InMemoryDefaults()
        FrontSessionStore.save(FrontSession(host: Self.remote, name: "work"), to: defaults)
        let store = emptyStore([Self.local, Self.remote], defaults: defaults)

        // The local daemon answers first, with nothing on it: a machine that
        // has just been restarted, which is the ordinary way to have none.
        list(store, [])
        store.switchHost(Self.local)
        XCTAssertEqual(store.currentHost, Self.local)

        // ...and now build-box answers, with the session that was remembered.
        list(store, host: Self.remote, [(7, "work", [1])])

        XCTAssertEqual(store.currentHost, Self.local, "a late restore moved the window")
        XCTAssertNil(store.selectedTabID)
        XCTAssertTrue(store.visibleTabs.isEmpty)
    }

    /// Standing on an empty machine is a place the window can rest, so it is a
    /// place it has to be able to reopen: the blob keeps the machine and simply
    /// has no name in it. Without this, ending the day on a machine you had
    /// just added — before making anything on it — reopened you somewhere else.
    func testStandingOnAnEmptyMachineIsRememberedAcrossLaunches() {
        let defaults = InMemoryDefaults()
        let store = emptyStore([Self.local, Self.remote], defaults: defaults)
        list(store, [(1, "here", [1])])
        list(store, host: Self.remote, [])
        XCTAssertEqual(defaults.writes[FrontSessionStore.key], 1)

        store.switchHost(Self.remote)

        XCTAssertEqual(FrontSessionStore.load(defaults), FrontSession(host: Self.remote, name: nil))
        XCTAssertEqual(
            defaults.writes[FrontSessionStore.key], 2,
            "the machine in front was written more than once, or not at all")

        // Which is what the next launch reads.
        let next = emptyStore([Self.local, Self.remote], defaults: defaults)
        XCTAssertEqual(next.currentHost, Self.remote)
        XCTAssertNil(next.selectedTabID)
    }

    /// Written through as it changes, because there is no termination hook in
    /// this app to write it at — and written only when it *has* changed, or
    /// every ⌘1 inside one session would be a write.
    func testTheFrontSessionIsRememberedAsItChanges() throws {
        let defaults = InMemoryDefaults()
        let store = emptyStore(defaults: defaults)
        list(store, [(1, "work", [1, 2]), (2, "spare", [3])])

        // The reconcile put the first tab in front, which is a session being
        // in front like any other.
        XCTAssertEqual(defaults.writes[FrontSessionStore.key], 1)
        XCTAssertEqual(FrontSessionStore.load(defaults)?.name, "work")

        // A tab switch inside that session is not a change of session.
        store.selectedTabID = try tab(store, 2).id
        XCTAssertEqual(
            defaults.writes[FrontSessionStore.key], 1,
            "⌘2 rewrote a front session that had not changed")

        store.selectedTabID = try tab(store, 3).id
        XCTAssertEqual(defaults.writes[FrontSessionStore.key], 2)
        XCTAssertEqual(
            FrontSessionStore.load(defaults), FrontSession(host: Self.local, name: "spare"))
    }

    // MARK: - What a new session is called, and where it goes
    //
    // Against a real socket, because the assertion is about the frame that
    // leaves: a `create` on a nil control connection is silently nothing, which
    // is exactly what a name this app refused also looks like.

    struct TimedOut: Error, CustomStringConvertible {
        var description: String
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(description)")
        throw TimedOut(description: "timed out waiting for \(description)")
    }

    /// A store whose hosts have live control connections, past the handshake —
    /// so every frame counted afterwards is one a test asked for.
    private func connected(
        _ servers: [RecordingServer]
    ) async throws -> (SessionStore, [HostConnection]) {
        let addresses = servers.map { ServerHost.local(socketPath: $0.path) }
        let store = SessionStore(
            hosts: addresses, defaults: InMemoryDefaults(),
            launcher: RecordingLauncher(.succeedSilently))
        var connections: [HostConnection] = []
        for address in addresses {
            connections.append(try XCTUnwrap(store.host(address), "no host"))
        }
        for connection in connections { connection.connect() }
        try await waitFor("the handshake") {
            servers.allSatisfy { $0.frames(.list).count == 1 }
        }
        return (store, connections)
    }

    private func createdNames(_ server: RecordingServer) throws -> [String] {
        try server.frames(.create).map {
            try JSONDecoder().decode(CreateBody.self, from: $0.payload).sessionName
        }
    }

    /// The lowest unused number, not one more than the count. A `create` is
    /// addressed by name and the daemon *joins* a session whose name it already
    /// has, so with `session-1` deleted and `session-2` still open, `count + 1`
    /// named the session already on screen — and "New Session" quietly opened a
    /// second tab in it.
    func testNewSessionPicksTheLowestUnusedName() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, hosts) = try await connected([server])
        defer { for host in hosts { host.disconnect() } }
        list(store, host: hosts[0].host, [(1, "session-1", [1]), (2, "session-2", [2])])
        list(store, host: hosts[0].host, [(2, "session-2", [2])])

        store.createSession()

        try await waitFor("the create") { !server.frames(.create).isEmpty }
        XCTAssertEqual(try createdNames(server), ["session-1"])
    }

    /// And it goes to the machine the window is on. Two machines each number
    /// their sessions from 1, so "session-1" is not evidence of anything on its
    /// own — which socket it left by is.
    func testCreateSessionGoesToTheCurrentHost() async throws {
        let here = try RecordingServer()
        let there = try RecordingServer()
        defer {
            here.stop()
            there.stop()
        }
        let (store, hosts) = try await connected([here, there])
        defer { for host in hosts { host.disconnect() } }
        list(store, host: hosts[0].host, [(1, "work", [1])])

        store.switchHost(hosts[1].host)
        store.createSession()

        try await waitFor("the create") { !there.frames(.create).isEmpty }
        XCTAssertEqual(try createdNames(there), ["session-1"])
        XCTAssertTrue(
            here.frames(.create).isEmpty,
            "the session was made on the machine the window had left")
    }

    /// ⌘T follows the machine the window is on, and a machine that cannot make
    /// a terminal says why rather than having its work done elsewhere.
    ///
    /// This used to assert the opposite: ⌘T went to "the first host that is
    /// connected", because `createTerminal` sends through `try?` and a ⌘T at a
    /// dead local daemon did nothing at all, silently. That answered a real
    /// problem in the one way nobody can follow — the terminal appeared on a
    /// machine nothing on screen named. The reason is on screen now instead.
    ///
    /// Socket-backed, and it lives here rather than in `TabReconcileTests` for
    /// that reason: the version there asserted `current?.host` and
    /// `currentHostError` and never made a terminal, so the reroute could have
    /// been put straight back inside `createTerminal` without reddening it.
    /// Which socket the frame left by is the only evidence there is.
    func testANewTerminalFollowsTheCurrentHostRatherThanWhoIsConnected() async throws {
        let here = try RecordingServer()
        let there = try RecordingServer()
        defer {
            here.stop()
            there.stop()
        }
        let (store, hosts) = try await connected([here, there])
        defer { for host in hosts { host.disconnect() } }

        // The machine the window is on has fallen over and the other one is
        // fine, so "the first host that is connected" is the *other* one. The
        // sockets stay open underneath, which is what lets this tell a refusal
        // from a reroute: a create really would arrive if one were sent.
        hosts[0].setStatusForTesting(.failed("No illogicald"))
        hosts[1].setStatusForTesting(.connected)

        XCTAssertEqual(store.current?.host, hosts[0].host, "⌘T was quietly rerouted")
        XCTAssertEqual(
            store.currentHostError, "No illogicald",
            "a machine that cannot make a terminal said nothing about why")

        store.createTerminal()

        try await waitFor("the create") { !here.frames(.create).isEmpty }
        XCTAssertTrue(
            there.frames(.create).isEmpty,
            "⌘T went to whichever machine happened to be connected")

        // And going to the working one is a thing the user does, not a thing
        // the store does behind them — after which ⌘T goes there and nowhere
        // else.
        store.switchHost(hosts[1].host)
        XCTAssertEqual(store.current?.host, hosts[1].host)
        XCTAssertNil(store.currentHostError)

        store.createTerminal()
        try await waitFor("the second create") { !there.frames(.create).isEmpty }
        XCTAssertEqual(here.frames(.create).count, 1, "the switch did not move ⌘T")
    }

    /// An `on:` naming a machine that is not in the list is refused, not sent
    /// somewhere else. The dropdown's rows and ＋ buttons all carry a host, and
    /// a host can be forgotten between the panel being drawn and a row being
    /// clicked — under `?? current` that made a terminal on whatever machine
    /// the window happened to be on, which is worse than the button doing
    /// nothing.
    func testACreateForAHostThatIsGoneIsRefusedRatherThanRerouted() async throws {
        let here = try RecordingServer()
        defer { here.stop() }
        let (store, hosts) = try await connected([here])
        defer { for host in hosts { host.disconnect() } }

        store.createTerminal(sessionName: "work", on: Self.remote)

        // Nothing arrives, and the way to be sure of that is to send something
        // that must: a frame the store *does* route proves the socket was
        // listening all along.
        store.createTerminal(sessionName: "real")
        try await waitFor("the create") { !here.frames(.create).isEmpty }
        XCTAssertEqual(
            try createdNames(here), ["real"],
            "a create for a machine that is not here was rerouted to the one that is")
    }

    // MARK: - What is remembered, and what is not this window's to remember

    /// A remembered machine that is not in this window's list is not somewhere
    /// to open on. Forget a host and relaunch, or launch with `ILLOGICAL_HOSTS`
    /// once and not the next time, and the blob names a machine that has no
    /// `HostConnection` — so `currentHost` would name a host `current` can
    /// never resolve. `current` nil for the life of the window: ⌘T does
    /// nothing, the strip is empty, and `currentHostError` cannot say why
    /// because it reads `current` too.
    func testARememberedMachineThatIsGoneIsNotOpenedOn() {
        let defaults = InMemoryDefaults()
        FrontSessionStore.save(FrontSession(host: Self.remote, name: "work"), to: defaults)

        let store = emptyStore([Self.local], defaults: defaults)

        XCTAssertEqual(store.currentHost, Self.local)
        XCTAssertNotNil(
            store.current, "the window opened on a machine it has no connection to")
    }

    /// The front session obeys the host list's provenance rule, because it is
    /// the same `UserDefaults`. A window handed its machines by the environment
    /// writes a blob naming one that will not be in the list next launch — so
    /// `init` drops it, and the session the person was really last in is gone
    /// with it. `scripts/bench-remote.sh` launches the shipped bundle with
    /// `ILLOGICAL_HOSTS`, and it, `bench-launch.sh` and `bench-attach.sh`
    /// launch it with `ILLOGICAL_SOCK`; all of them write to the developer's
    /// real defaults, since only the tests get a `HostDefaults` of their own.
    ///
    /// Driven through the parameterized form for the reason
    /// `hostsToRemember(injected:)` has one: both signals come from
    /// `ProcessInfo`, which cannot be changed underneath a running process.
    func testAnInjectedMachineIsNotRememberedAsTheFrontSession() {
        let defaults = InMemoryDefaults()
        let store = emptyStore([Self.local, Self.remote], defaults: defaults)

        store.rememberFront(
            FrontSession(host: Self.remote, name: "work"), injected: [Self.remote],
            socketInjected: false)
        XCTAssertNil(
            FrontSessionStore.load(defaults),
            "an ILLOGICAL_HOSTS machine overwrote the remembered front session")

        // The local half is the same rule through the other injection point:
        // the local daemon is never on disk, so "is it saved" has no answer for
        // it and "did the environment name it" is the same question.
        store.rememberFront(
            FrontSession(host: Self.local, name: "here"), injected: [], socketInjected: true)
        XCTAssertNil(
            FrontSessionStore.load(defaults), "an ILLOGICAL_SOCK window wrote a front session")

        // And a machine somebody actually added is written, injected list or
        // not — the union clause `hostsToRemember` already has.
        RemoteHostStore.save([Self.remote], to: defaults)
        store.rememberFront(
            FrontSession(host: Self.remote, name: "work"), injected: [Self.remote],
            socketInjected: false)
        XCTAssertEqual(
            FrontSessionStore.load(defaults), FrontSession(host: Self.remote, name: "work"))
    }

    /// The remembered session is checked at use rather than trusted. It is
    /// never pruned — walking it on every list from every host would save
    /// nothing anybody can measure — so an entry outlives the session it names
    /// whenever another window deletes one while you are elsewhere.
    ///
    /// Both readers. Coming back to the machine must land on its first session
    /// rather than on whatever tab happens to be first, and with no tabs at all
    /// `selectedSession` must be nil: a stale ref there is what the session
    /// button draws its name from, and it is what leaves File ▸ Rename
    /// Session… enabled for a session that is not there, whose only effect when
    /// chosen is `requestRenameSession`'s guard refusing it silently.
    func testARememberedSessionThatWasDeletedIsNotComeBackTo() throws {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "here", [1])])
        // Each session holding a terminal from later than its own position, so
        // that "the machine's first session" and "the machine's first tab" are
        // two different answers — `a` is first and its tab is last.
        list(
            store, host: Self.remote, [(1, "a", [5]), (2, "b", [4]), (3, "c", [3])],
            terminalOrder: [3, 4, 5])

        store.selectedTabID = try tab(store, 4, on: Self.remote).id
        store.switchHost(Self.local)

        // Another window deletes `b` while we are on the local machine.
        list(store, host: Self.remote, [(1, "a", [5]), (3, "c", [3])], terminalOrder: [3, 5])

        store.switchHost(Self.remote)

        XCTAssertEqual(
            store.selectedSession?.session, 1,
            "it came back to a deleted session, so the repair fell through to a tab")
        XCTAssertEqual(store.selectedTabID, try tab(store, 5, on: Self.remote).id)

        // ...and with the machine emptied entirely there is no session to name,
        // rather than the last one it remembers.
        list(store, host: Self.remote, [])
        XCTAssertNil(
            store.selectedSession, "the session button named a session the machine no longer has")
        XCTAssertNil(store.selectedSessionSummary)
    }

    /// A machine still dialling says nothing. `.connecting` is where every
    /// `HostConnection` starts and where the whole launch restore sits — the
    /// window opens on the remembered machine and shows its empty screen for
    /// the length of an ssh handshake, which behind 2FA is a long time — so a
    /// message here is a failure flashed at somebody on every launch.
    /// `currentHostError` is pinned for `.reconnecting`, `.connected` and
    /// `.failed`; this is the state all three are measured against.
    func testACurrentHostStillDiallingSaysNothingYet() {
        let defaults = InMemoryDefaults()
        FrontSessionStore.save(FrontSession(host: Self.remote, name: "work"), to: defaults)
        let store = emptyStore([Self.local, Self.remote], defaults: defaults)

        XCTAssertEqual(store.currentHost, Self.remote)
        XCTAssertEqual(store.host(Self.remote)?.status, .connecting)
        XCTAssertNil(store.currentHostError, "a handshake was reported as a failure")

        // Still nothing once the local daemon has answered and the window is
        // still standing on the machine that has not.
        list(store, [(1, "here", [1])])
        XCTAssertNil(store.currentHostError)
        XCTAssertNil(store.connectionError)

        // Only a machine that has actually gone wrong says so.
        store.host(Self.remote)?.setStatusForTesting(.failed("build-box: Connection refused"))
        XCTAssertEqual(store.currentHostError, "build-box: Connection refused")
    }
}
