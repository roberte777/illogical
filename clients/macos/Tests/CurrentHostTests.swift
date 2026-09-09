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
    private func list(_ store: SessionStore, host: ServerHost = local, _ sessions: [Listing]) {
        guard let connection = store.host(host) else { return XCTFail("no such host") }
        connection.sessions = sessions.map {
            SessionSummary(id: $0.id, name: $0.name, terminals: $0.terminals)
        }
        connection.terminals = sessions.flatMap { session in
            session.terminals.map { terminal($0, session: session.id) }
        }
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

        // ...and asking for the machine you are already on is not a move. The
        // menu's checked row is still a row somebody can click, and the memory
        // is of a session rather than a tab — so without that guard this would
        // drop you on the first tab of the session you are already in.
        let third = try tab(store, 3, on: Self.remote).id
        store.selectedTabID = third
        store.switchHost(Self.remote)
        XCTAssertEqual(store.selectedTabID, third, "it moved inside the session it was in")
    }

    /// A machine this window has never been on has no memory to honour, so it
    /// opens on the first session the machine lists.
    func testSwitchHostFallsBackToTheFirstSession() throws {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "here", [1])])
        list(store, host: Self.remote, [(1, "a", [1]), (2, "b", [2])])
        store.selectedTabID = try tab(store, 1).id

        store.switchHost(Self.remote)

        XCTAssertEqual(store.selectedTabID, try tab(store, 1, on: Self.remote).id)
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

    /// Forgetting the machine you are on has to leave the window somewhere.
    /// `hosts[0]` is the local daemon, which is the one host that cannot be
    /// removed.
    func testRemovingTheCurrentHostFallsBackToLocal() throws {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "here", [1])])
        list(store, host: Self.remote, [(1, "there", [1])])
        store.switchHost(Self.remote)

        store.removeHost(Self.remote)

        XCTAssertEqual(store.currentHost, Self.local)
        XCTAssertEqual(store.selectedTabID, try tab(store, 1).id)
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
        XCTAssertNil(store.selectedTabID)
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
    func testARestoreNamingAGoneSessionFallsBackToTheHostsFirst() throws {
        let defaults = InMemoryDefaults()
        FrontSessionStore.save(FrontSession(host: Self.local, name: "work"), to: defaults)
        let store = emptyStore(defaults: defaults)

        list(store, [(3, "scratch", [1])])

        XCTAssertEqual(store.selectedTabID, try tab(store, 1).id)
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
}
