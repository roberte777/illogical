//  TabReconcileTests.swift
//  Keeping the tab list in line with what every host says exists.
//
//  Every interesting case here is a race between what a server lists and what
//  the client already did: a pane closed locally that the server still reports,
//  a terminal that died on its own, a split whose second terminal must not also
//  become a tab of its own.
//
//  The store is driven without a socket. `HostConnection` publishes its
//  session list as plain properties, so setting them and calling
//  `reconcileTabs()` is the same path a `session_list` frame takes.

import IllogicalProtocol
import XCTest

@MainActor
final class TabReconcileTests: XCTestCase {
    private static let local = ServerHost.local(socketPath: "/tmp/illogical-test.sock")
    private static let remote = ServerHost.ssh(destination: "build-box")

    /// A store with one host and nothing on it.
    private func emptyStore(_ hosts: [ServerHost] = [local]) -> SessionStore {
        // A throwaway defaults suite: `addHost`/`removeHost` persist, and a
        // unit test must not write to the developer's real preferences.
        let suite = UserDefaults(suiteName: "illogical-test-\(UUID().uuidString)") ?? .standard
        return SessionStore(hosts: hosts, defaults: suite)
    }

    private func store(_ ids: [UInt64], session: UInt64 = 1) -> SessionStore {
        let store = emptyStore()
        list(store, host: Self.local, ids, session: session)
        return store
    }

    /// What a `session_list` frame does, without a socket.
    private func list(
        _ store: SessionStore, host: ServerHost, _ ids: [UInt64], session: UInt64 = 1,
        named name: String = "s"
    ) {
        guard let connection = store.host(host) else { return XCTFail("no such host") }
        connection.sessions = [SessionSummary(id: session, name: name, terminals: ids)]
        connection.terminals = ids.map { terminal($0, session: session) }
        store.reconcileTabs()
    }

    private func terminal(_ id: UInt64, session: UInt64 = 1) -> TerminalSummary {
        TerminalSummary(
            id: id, session: session, name: "t\(id)", command: "/bin/zsh", cwd: "/",
            cols: 80, rows: 24, residency: .live, attached: 0, ptyReadIdleNanoseconds: 0)
    }

    private func relist(_ store: SessionStore, _ ids: [UInt64]) {
        list(store, host: Self.local, ids)
    }

    private func ref(_ id: UInt64, on host: ServerHost = local) -> TerminalRef {
        TerminalRef(host: host, terminal: id)
    }

    private func pane(_ id: UInt64, on host: ServerHost = local) -> Pane {
        Pane(terminal: ref(id, on: host))
    }

    private func terminals(_ store: SessionStore) -> [UInt64] {
        store.tabs.flatMap { $0.panes.map(\.terminal.terminal) }
    }

    func testEveryTerminalGetsATab() {
        let store = store([1, 2, 3])
        XCTAssertEqual(store.tabs.count, 3)
        XCTAssertEqual(terminals(store), [1, 2, 3])
        XCTAssertEqual(store.selectedTabID, store.tabs.first?.id)
    }

    /// A terminal that is a pane inside a tab must not also become a tab. That
    /// is the whole difference between a split and a second tab.
    func testASplitPaneDoesNotBecomeItsOwnTab() {
        let store = store([1])
        let tab = store.tabs[0]
        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: pane(2), direction: .columns)

        relist(store, [1, 2])

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(terminals(store), [1, 2])
    }

    /// A terminal that exits takes its pane with it and the split collapses,
    /// leaving the tab alive.
    func testADeadPaneCollapsesTheSplit() {
        let store = store([1])
        let tab = store.tabs[0]
        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: pane(2), direction: .columns)
        relist(store, [1, 2])

        relist(store, [1])

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(terminals(store), [1])
        XCTAssertFalse(store.tabs[0].isSplit)
        XCTAssertEqual(store.tabs[0].focused, store.tabs[0].panes[0].id)
    }

    /// The *root* pane dying is the case a tab keyed by its terminal cannot
    /// survive. This one can: the tab has its own identity.
    func testTheTabOutlivesItsFirstTerminal() {
        let store = store([1])
        let tab = store.tabs[0]
        let tabID = tab.id
        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: pane(2), direction: .rows)
        relist(store, [1, 2])

        relist(store, [2])

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].id, tabID)
        XCTAssertEqual(terminals(store), [2])
        XCTAssertEqual(store.selectedTabID, tabID)
    }

    func testATabWithNoPanesLeftIsDropped() {
        let store = store([1, 2])
        relist(store, [2])

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(terminals(store), [2])
        XCTAssertEqual(store.selectedTabID, store.tabs[0].id)
    }

    /// Closing a pane removes it immediately, before the server confirms. The
    /// next list still mentions the terminal, and must not put the tab back.
    func testAClosedPaneIsNotResurrectedByTheNextList() {
        let store = store([1])
        let tab = store.tabs[0]
        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: pane(2), direction: .columns)
        relist(store, [1, 2])

        let second = store.tabs[0].panes[1]
        store.closePane(second.id, in: store.tabs[0].id)
        XCTAssertEqual(terminals(store), [1])

        // The server has not caught up yet.
        relist(store, [1, 2])
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(terminals(store), [1])

        // And once it has, nothing changes.
        relist(store, [1])
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(terminals(store), [1])
    }

    func testClosingTheLastPaneClosesTheTab() {
        let store = store([1, 2])
        let tab = store.tabs[0]
        store.closePane(tab.panes[0].id, in: tab.id)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(terminals(store), [2])
    }

    // MARK: - Focus and zoom

    func testFocusMovesBetweenPanes() {
        let store = store([1])
        let tab = store.tabs[0]
        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: pane(2), direction: .columns)
        let left = store.tabs[0].panes[0]
        let right = store.tabs[0].panes[1]
        store.tabs[0].focused = left.id

        store.moveFocus(.right)
        XCTAssertEqual(store.tabs[0].focused, right.id)
        XCTAssertEqual(store.selectedRef, ref(2))

        store.moveFocus(.left)
        XCTAssertEqual(store.tabs[0].focused, left.id)
        XCTAssertEqual(store.selectedRef, ref(1))

        // Nowhere to go, so nothing moves.
        store.moveFocus(.up)
        XCTAssertEqual(store.tabs[0].focused, left.id)
    }

    /// The tab is named by its focused pane, so a split tab says what you are
    /// working in rather than what it started as.
    func testTheTabLabelFollowsFocus() {
        let store = store([1])
        let tab = store.tabs[0]
        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: pane(2), direction: .columns)
        store.host(Self.local)?.terminals = [terminal(1), terminal(2)]

        store.tabs[0].focused = store.tabs[0].panes[1].id
        XCTAssertEqual(store.label(for: store.tabs[0])?.id, 2)
    }

    func testZoomOnlyAppliesToASplitTab() {
        let store = store([1])
        let tab = store.tabs[0]
        store.toggleZoom(tab.focused, in: tab.id)
        XCTAssertNil(store.tabs[0].zoomed, "nothing to zoom out of with one pane")

        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: pane(2), direction: .columns)
        let right = store.tabs[0].panes[1]

        store.toggleZoom(right.id, in: tab.id)
        XCTAssertEqual(store.tabs[0].zoomed, right.id)
        XCTAssertEqual(store.tabs[0].focused, right.id)

        store.toggleZoom(right.id, in: tab.id)
        XCTAssertNil(store.tabs[0].zoomed)
    }

    /// Focus moves are geometric, and a zoomed pane has no geometry to move
    /// through — the others are not on screen.
    func testFocusDoesNotMoveWhileZoomed() {
        let store = store([1])
        let tab = store.tabs[0]
        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: pane(2), direction: .columns)
        let left = store.tabs[0].panes[0]
        store.tabs[0].focused = left.id
        store.toggleZoom(left.id, in: tab.id)

        store.moveFocus(.right)
        XCTAssertEqual(store.tabs[0].focused, left.id)
    }

    // MARK: - Tabs and sessions

    func testTabsAreFilteredToTheSelectedSession() {
        let store = emptyStore()
        guard let host = store.host(Self.local) else { return XCTFail("no host") }
        host.sessions = [
            SessionSummary(id: 1, name: "a", terminals: [1]),
            SessionSummary(id: 2, name: "b", terminals: [2]),
        ]
        host.terminals = [terminal(1, session: 1), terminal(2, session: 2)]
        store.reconcileTabs()

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.visibleTabs.count, 1)
        XCTAssertEqual(store.selectedSession?.session, 1)

        store.selectedTabID = store.tabs[1].id
        XCTAssertEqual(store.selectedSession?.session, 2)
        XCTAssertEqual(store.visibleTabs.map(\.id), [store.tabs[1].id])
    }

    // MARK: - More than one machine
    //
    // This is what M5 is for. Two hosts both number their terminals from 1, so
    // everything above has to be keyed by `TerminalRef` rather than by id --
    // and the failure mode of getting it wrong is not a missing tab, it is one
    // machine's terminal drawn in the other's pane.

    func testTwoHostsBothNumberFromOneWithoutColliding() {
        let store = emptyStore([Self.local, Self.remote])
        list(store, host: Self.local, [1, 2], named: "here")
        list(store, host: Self.remote, [1, 3], named: "there")

        XCTAssertEqual(store.tabs.count, 4)
        // Two panes claim to be terminal 1, and they are different terminals.
        let ones = store.tabs.filter { $0.panes.contains { $0.terminal.terminal == 1 } }
        XCTAssertEqual(ones.count, 2)
        XCTAssertEqual(Set(ones.map(\.session.host)), [Self.local, Self.remote])
    }

    /// A terminal going away on one machine must not take the same-numbered
    /// terminal on the other one with it.
    func testATerminalDyingOnOneHostLeavesTheOtherAlone() {
        let store = emptyStore([Self.local, Self.remote])
        list(store, host: Self.local, [1, 2])
        list(store, host: Self.remote, [1])
        XCTAssertEqual(store.tabs.count, 3)

        list(store, host: Self.local, [2])

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(
            Set(store.tabs.flatMap { $0.panes.map(\.terminal) }),
            [ref(2), ref(1, on: Self.remote)])
    }

    /// Sessions are per machine, so the tab strip shows one machine's at a
    /// time — the session button says which.
    func testTabsAreFilteredToTheSelectedHostsSession() {
        let store = emptyStore([Self.local, Self.remote])
        list(store, host: Self.local, [1], named: "here")
        list(store, host: Self.remote, [1], named: "there")

        store.selectedTabID = store.tabs[0].id
        XCTAssertEqual(store.selectedSession?.host, Self.local)
        XCTAssertEqual(store.visibleTabs.count, 1)
        XCTAssertEqual(store.visibleTabs[0].panes[0].terminal, ref(1))

        store.selectedTabID = store.tabs[1].id
        XCTAssertEqual(store.selectedSession?.host, Self.remote)
        XCTAssertEqual(store.visibleTabs.count, 1)
        XCTAssertEqual(store.visibleTabs[0].panes[0].terminal, ref(1, on: Self.remote))
    }

    /// Forgetting a machine takes its tabs with it, even though it is no
    /// longer there to report that its terminals are gone.
    func testRemovingAHostTakesItsTabs() {
        let store = emptyStore([Self.local, Self.remote])
        // `removeHost` persists; give it somewhere that is not the developer's
        // real defaults.
        list(store, host: Self.local, [1])
        list(store, host: Self.remote, [1, 2])
        XCTAssertEqual(store.tabs.count, 3)

        store.removeHost(Self.remote)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].panes[0].terminal, ref(1))
        XCTAssertEqual(store.selectedTabID, store.tabs[0].id)
        XCTAssertNil(store.host(Self.remote))
    }

    /// The local daemon is not something the user added, and removing it would
    /// leave nowhere to make a terminal.
    func testTheLocalHostCannotBeRemoved() {
        let store = emptyStore([Self.local, Self.remote])
        list(store, host: Self.local, [1])

        store.removeHost(Self.local)

        XCTAssertNotNil(store.host(Self.local))
        XCTAssertEqual(store.tabs.count, 1)
    }

    /// A destination already in the list is one machine, not two.
    ///
    /// `connect: false` on purpose: the connecting form spawns a real
    /// `ssh build-box illogicald --stdio` and creates `~/.ssh`, which a unit
    /// test has no business doing.
    func testAddingAHostTwiceIsIdempotent() {
        let store = emptyStore([Self.local])
        let before = store.hosts.count
        store.addHost(Self.remote, connect: false)
        let first = store.host(Self.remote)
        store.addHost(Self.remote, connect: false)

        XCTAssertEqual(store.hosts.count, before + 1)
        // Identity, not just the count: replacing the entry would keep the
        // count and orphan the first connection's control pump and every live
        // controller on it — every open remote pane goes dead and an ssh
        // process leaks, with the count still right.
        XCTAssertTrue(store.host(Self.remote) === first)
    }

    /// One unreachable machine must not take the window over. The previous
    /// version of this test never put a host into `.failed` at all, so it
    /// asserted nil against a store with no failures — true under any
    /// implementation, including one where a single failure blanks the window.
    func testOneFailedHostIsNotAWindowWideErrorButAllOfThemIs() {
        let store = emptyStore([Self.local, Self.remote])
        list(store, host: Self.local, [1])
        store.host(Self.local)?.setStatusForTesting(.connected)
        store.host(Self.remote)?.setStatusForTesting(.failed("could not resolve hostname"))

        XCTAssertNil(store.connectionError, "one dead remote blanked a working window")

        // ...and when nothing is reachable, it says so, with the message.
        store.host(Self.local)?.setStatusForTesting(.failed("No illogicald"))
        XCTAssertEqual(store.connectionError, "No illogicald")
    }

    /// A new terminal must go to a machine that can actually make one.
    /// `hosts.first` is always the local daemon, and `createTerminal` sends
    /// through `try?`, so with no local daemon every ⌘T silently did nothing.
    func testNewTerminalsAvoidAHostThatIsNotConnected() {
        let store = emptyStore([Self.local, Self.remote])
        store.host(Self.local)?.setStatusForTesting(.failed("No illogicald"))
        store.host(Self.remote)?.setStatusForTesting(.connected)

        XCTAssertEqual(store.selectedHost?.host, Self.remote)
    }

    /// Persistence round-trips, and `ILLOGICAL_HOSTS` entries are not written.
    func testOnlyUserAddedHostsAreRemembered() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "illogical-test-\(UUID().uuidString)"))
        defer { suite.removePersistentDomain(forName: suite.description) }

        let store = SessionStore(hosts: [Self.local], defaults: suite)
        store.addHost(Self.remote, connect: false)

        XCTAssertEqual(RemoteHostStore.load(suite), [Self.remote])
        // And the local host is never stored: it is wherever this machine puts
        // its socket, not something the user chose.
        XCTAssertFalse(RemoteHostStore.load(suite).contains(Self.local))
    }

    /// Two hosts number their sessions from 1 as well as their terminals, so a
    /// split must not resolve the front session's *id* against another machine.
    func testASplitStaysOnItsOwnHostsSession() {
        let store = emptyStore([Self.local, Self.remote])
        list(store, host: Self.local, [1], session: 1, named: "here")
        list(store, host: Self.remote, [1], session: 1, named: "there")

        let remoteTab = store.tabs.first { $0.session.host == Self.remote }
        XCTAssertEqual(remoteTab?.session.session, 1)
        XCTAssertEqual(remoteTab?.session.host, Self.remote)
        // The two sessions share an id and differ only by host, which is the
        // whole reason `SessionRef` exists.
        XCTAssertNotEqual(
            store.tabs[0].session, store.tabs[1].session,
            "two hosts' session 1 compared equal")
    }

}
