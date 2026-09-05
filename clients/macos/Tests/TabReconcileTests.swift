//  TabReconcileTests.swift
//  Keeping the tab list in line with what the server says exists.
//
//  Every interesting case here is a race between what the server lists and
//  what the client already did: a pane closed locally that the server still
//  reports, a terminal that died on its own, a split whose second terminal
//  must not also become a tab of its own.

import IllogicalProtocol
import XCTest

@MainActor
final class TabReconcileTests: XCTestCase {
    private func store(_ ids: [UInt64], session: UInt64 = 1) -> SessionStore {
        let store = SessionStore()
        store.sessions = [SessionSummary(id: session, name: "s", terminals: ids)]
        store.terminals = ids.map { terminal($0, session: session) }
        store.reconcileTabs(live: Set(ids))
        return store
    }

    private func terminal(_ id: UInt64, session: UInt64 = 1) -> TerminalSummary {
        TerminalSummary(
            id: id, session: session, name: "t\(id)", command: "/bin/zsh", cwd: "/",
            cols: 80, rows: 24, residency: .live, attached: 0, ptyReadIdleNanoseconds: 0)
    }

    private func relist(_ store: SessionStore, _ ids: [UInt64]) {
        store.terminals = ids.map { terminal($0) }
        store.reconcileTabs(live: Set(ids))
    }

    func testEveryTerminalGetsATab() {
        let store = store([1, 2, 3])
        XCTAssertEqual(store.tabs.count, 3)
        XCTAssertEqual(store.tabs.flatMap { $0.panes.map(\.terminalID) }, [1, 2, 3])
        XCTAssertEqual(store.selectedTabID, store.tabs.first?.id)
    }

    /// A terminal that is a pane inside a tab must not also become a tab. That
    /// is the whole difference between a split and a second tab.
    func testASplitPaneDoesNotBecomeItsOwnTab() {
        let store = store([1])
        let tab = store.tabs[0]
        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: Pane(terminalID: 2), direction: .columns)

        relist(store, [1, 2])

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].panes.map(\.terminalID), [1, 2])
    }

    /// A terminal that exits takes its pane with it and the split collapses,
    /// leaving the tab alive.
    func testADeadPaneCollapsesTheSplit() {
        let store = store([1])
        let tab = store.tabs[0]
        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: Pane(terminalID: 2), direction: .columns)
        relist(store, [1, 2])

        relist(store, [1])

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].panes.map(\.terminalID), [1])
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
            tab.focused, with: Pane(terminalID: 2), direction: .rows)
        relist(store, [1, 2])

        relist(store, [2])

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].id, tabID)
        XCTAssertEqual(store.tabs[0].panes.map(\.terminalID), [2])
        XCTAssertEqual(store.selectedTabID, tabID)
    }

    func testATabWithNoPanesLeftIsDropped() {
        let store = store([1, 2])
        relist(store, [2])

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].panes.map(\.terminalID), [2])
        XCTAssertEqual(store.selectedTabID, store.tabs[0].id)
    }

    /// Closing a pane removes it immediately, before the server confirms. The
    /// next list still mentions the terminal, and must not put the tab back.
    func testAClosedPaneIsNotResurrectedByTheNextList() {
        let store = store([1])
        let tab = store.tabs[0]
        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: Pane(terminalID: 2), direction: .columns)
        relist(store, [1, 2])

        let second = store.tabs[0].panes[1]
        store.closePane(second.id, in: store.tabs[0].id)
        XCTAssertEqual(store.tabs[0].panes.map(\.terminalID), [1])

        // The server has not caught up yet.
        relist(store, [1, 2])
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].panes.map(\.terminalID), [1])

        // And once it has, nothing changes.
        relist(store, [1])
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].panes.map(\.terminalID), [1])
    }

    func testClosingTheLastPaneClosesTheTab() {
        let store = store([1, 2])
        let tab = store.tabs[0]
        store.closePane(tab.panes[0].id, in: tab.id)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].panes.map(\.terminalID), [2])
    }

    // MARK: - Focus and zoom

    func testFocusMovesBetweenPanes() {
        let store = store([1])
        let tab = store.tabs[0]
        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: Pane(terminalID: 2), direction: .columns)
        let left = store.tabs[0].panes[0]
        let right = store.tabs[0].panes[1]
        store.tabs[0].focused = left.id

        store.moveFocus(.right)
        XCTAssertEqual(store.tabs[0].focused, right.id)
        XCTAssertEqual(store.selectedID, 2)

        store.moveFocus(.left)
        XCTAssertEqual(store.tabs[0].focused, left.id)
        XCTAssertEqual(store.selectedID, 1)

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
            tab.focused, with: Pane(terminalID: 2), direction: .columns)
        store.terminals = [terminal(1), terminal(2)]

        store.tabs[0].focused = store.tabs[0].panes[1].id
        XCTAssertEqual(store.label(for: store.tabs[0])?.id, 2)
    }

    func testZoomOnlyAppliesToASplitTab() {
        let store = store([1])
        let tab = store.tabs[0]
        store.toggleZoom(tab.focused, in: tab.id)
        XCTAssertNil(store.tabs[0].zoomed, "nothing to zoom out of with one pane")

        store.tabs[0].root = tab.root.splitting(
            tab.focused, with: Pane(terminalID: 2), direction: .columns)
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
            tab.focused, with: Pane(terminalID: 2), direction: .columns)
        let left = store.tabs[0].panes[0]
        store.tabs[0].focused = left.id
        store.toggleZoom(left.id, in: tab.id)

        store.moveFocus(.right)
        XCTAssertEqual(store.tabs[0].focused, left.id)
    }

    // MARK: - Tabs and sessions

    func testTabsAreFilteredToTheSelectedSession() {
        let store = SessionStore()
        store.sessions = [
            SessionSummary(id: 1, name: "a", terminals: [1]),
            SessionSummary(id: 2, name: "b", terminals: [2]),
        ]
        store.terminals = [terminal(1, session: 1), terminal(2, session: 2)]
        store.reconcileTabs(live: [1, 2])

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.visibleTabs.count, 1)
        XCTAssertEqual(store.selectedSession?.id, 1)

        store.selectedTabID = store.tabs[1].id
        XCTAssertEqual(store.selectedSession?.id, 2)
        XCTAssertEqual(store.visibleTabs.map(\.id), [store.tabs[1].id])
    }
}
