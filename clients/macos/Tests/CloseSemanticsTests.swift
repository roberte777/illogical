//  CloseSemanticsTests.swift
//  What ⌘W and ⇧⌘W are allowed to destroy.
//
//  Issue #41: ⌘W used to close the *window* whenever the tab was not split, so
//  three unsplit tabs meant one ⌘W took all three. The policy is in
//  `SessionStore` rather than in `TerminalPane` precisely so it can be asserted
//  without a window — and `TerminalPane`'s coordinator is in the test target
//  too, so the one line that connects them cannot quietly go back to `false`.
//
//  Two things every decline is checked for, because both have been wrong:
//  nothing was mutated, and **nothing was killed**. Closing the window leaves
//  every terminal in it running — the empty state promises exactly that — so a
//  ⌘W that declines and hangs up on the way out would be the worse half of the
//  original bug.
//
//  The store is driven without a socket, the way `TabReconcileTests` drives it:
//  a `HostConnection` publishes its lists as plain properties, so setting them
//  and calling `reconcileTabs()` is the path a `session_list` frame takes.

import IllogicalProtocol
import XCTest

@MainActor
final class CloseSemanticsTests: XCTestCase {
    private static let local = ServerHost.local(socketPath: "/tmp/illogical-close-test.sock")

    /// Nothing here reaches the developer's real preferences.
    private final class InMemoryDefaults: HostDefaults {
        private var values: [String: Data] = [:]
        func data(forKey defaultName: String) -> Data? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) {
            values[defaultName] = value as? Data
        }
    }

    private func terminal(_ id: UInt64, session: UInt64 = 1) -> TerminalSummary {
        TerminalSummary(
            id: id, session: session, name: "t\(id)", command: "/bin/zsh", cwd: "/",
            cols: 80, rows: 24, residency: .live, attached: 0, ptyReadIdleNanoseconds: 0)
    }

    /// A store holding one tab per id, all in one session.
    private func store(_ ids: [UInt64]) -> SessionStore {
        let store = SessionStore(hosts: [Self.local], defaults: InMemoryDefaults())
        guard let host = store.host(Self.local) else { return store }
        host.sessions = [SessionSummary(id: 1, name: "s", terminals: ids)]
        host.terminals = ids.map { terminal($0) }
        store.reconcileTabs()
        return store
    }

    /// A store with a tab in each of two sessions on the same machine.
    private func twoSessionStore() -> SessionStore {
        let store = SessionStore(hosts: [Self.local], defaults: InMemoryDefaults())
        guard let host = store.host(Self.local) else { return store }
        host.sessions = [
            SessionSummary(id: 1, name: "a", terminals: [1]),
            SessionSummary(id: 2, name: "b", terminals: [2]),
        ]
        host.terminals = [terminal(1, session: 1), terminal(2, session: 2)]
        store.reconcileTabs()
        return store
    }

    /// A tab by position, as a failure rather than a trap. An unguarded
    /// `store.tabs[0]` on an empty list kills the xctest process and takes
    /// every remaining test in the bundle with it.
    private func tab(_ store: SessionStore, _ index: Int) throws -> TabLayout {
        try XCTUnwrap(
            store.tabs.indices.contains(index) ? store.tabs[index] : nil,
            "no tab at \(index): the store holds \(store.tabs.count)")
    }

    /// Split the tab at `index`, adding a pane for terminal `id`.
    @discardableResult
    private func split(_ store: SessionStore, _ index: Int, with id: UInt64) throws -> Pane {
        let pane = Pane(terminal: TerminalRef(host: Self.local, terminal: id))
        let tab = try tab(store, index)
        store.tabs[index].root = tab.root.splitting(
            tab.focused, with: pane, direction: .columns)
        return pane
    }

    private func terminals(_ store: SessionStore) -> [UInt64] {
        store.tabs.flatMap { $0.panes.map(\.terminal.terminal) }
    }

    // MARK: - closeSurfacePane (⌘W)

    /// The #41 repro, at the level the bug lived at. One unsplit tab among
    /// three: ⌘W closes that tab and the window stays.
    func testCommandWClosesOneOfSeveralUnsplitTabs() throws {
        let store = store([1, 2, 3])
        let tab = try tab(store, 1)

        XCTAssertTrue(store.closeSurfacePane(tab.focused, in: tab.id))

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(terminals(store), [1, 3])
        XCTAssertTrue(store.tabs.contains { $0.id == store.selectedTabID })
    }

    /// A split tab: the focused pane goes, the tab stays.
    func testCommandWClosesOnePaneOfASplitTab() throws {
        let store = store([1])
        let added = try split(store, 0, with: 2)
        let tab = try tab(store, 0)

        XCTAssertTrue(store.closeSurfacePane(added.id, in: tab.id))

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(terminals(store), [1])
        XCTAssertFalse(try self.tab(store, 0).isSplit)
    }

    /// The one case that still belongs to the window: the last pane of the last
    /// tab. The surface declines and `performClose` falls through.
    ///
    /// And nothing is hung up on the way. The window going away is a detach —
    /// "Sessions keep running after you close this window" — so a decline that
    /// killed the terminal would lose the shell the user was in.
    func testTheLastPaneOfTheLastTabDeclines() throws {
        let store = store([1])
        let tab = try tab(store, 0)

        XCTAssertFalse(store.closeSurfacePane(tab.focused, in: tab.id))

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(terminals(store), [1])
        XCTAssertTrue(store.closing.isEmpty, "declining ⌘W hung up the terminal anyway")
    }

    /// `tabs.count`, not `visibleTabs.count`. The front session has one tab, so
    /// a window-scoped check on the *visible* strip would have closed the
    /// window — and taken the other session's tab, which is not on screen, with
    /// it.
    func testAWindowHoldingAnotherSessionsTabsDoesNotClose() throws {
        let store = twoSessionStore()
        let front = try XCTUnwrap(store.selectedTab)
        XCTAssertEqual(store.visibleTabs.count, 1, "the premise: one tab in front")
        XCTAssertEqual(store.tabs.count, 2, "...and another session's behind it")

        XCTAssertTrue(store.closeSurfacePane(front.focused, in: front.id))

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(terminals(store), [2])
        XCTAssertEqual(store.selectedTabID, try tab(store, 0).id)
        XCTAssertEqual(store.selectedSession?.session, 2)
    }

    /// A tab that is not there any more — the reconcile dropped it while a
    /// stale surface was still holding a reference.
    func testAnUnknownTabDeclinesWithoutClosingAnything() {
        let store = store([1, 2])
        XCTAssertFalse(store.closeSurfacePane(UUID(), in: UUID()))
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertTrue(store.closing.isEmpty)
    }

    /// A real tab, a pane id it no longer holds. Reporting success for that
    /// swallowed the keystroke whole: no pane closed, and no fall-through to
    /// the window either.
    func testAStalePaneIdIsNotReportedAsClosed() throws {
        let store = store([1, 2])
        let tab = try tab(store, 0)

        XCTAssertFalse(store.closeSurfacePane(UUID(), in: tab.id))

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(terminals(store), [1, 2])
        XCTAssertTrue(store.closing.isEmpty)
    }

    // MARK: - The pane view's delegate
    //
    // One line, and it is the line #41 was about. Without `TerminalPane.swift`
    // in the test target, rewriting it to `return false` — the original bug,
    // one level up from where the fix went — failed nothing.

    private func coordinator(
        _ store: SessionStore, pane: UUID, tab: TabLayout.ID
    )
        -> TerminalSurface.Coordinator
    {
        TerminalSurface.Coordinator(
            store: store, terminal: TerminalRef(host: Self.local, terminal: 1),
            pane: pane, tab: tab)
    }

    func testThePaneDelegateClosesThroughTheStore() throws {
        let store = store([1, 2])
        let tab = try tab(store, 0)
        let view = TerminalSurfaceView(frame: .zero)

        let closed = coordinator(store, pane: tab.focused, tab: tab.id)
            .surfaceShouldClose(view)

        XCTAssertTrue(closed, "the delegate refused a close the store allows")
        XCTAssertEqual(terminals(store), [2])
    }

    func testThePaneDelegateDeclinesForTheWindowsLastTerminal() throws {
        let store = store([1])
        let tab = try tab(store, 0)
        let view = TerminalSurfaceView(frame: .zero)

        let closed = coordinator(store, pane: tab.focused, tab: tab.id)
            .surfaceShouldClose(view)

        XCTAssertFalse(closed, "the window never got the chance to close")
        XCTAssertEqual(terminals(store), [1])
        XCTAssertTrue(store.closing.isEmpty)
    }

    // MARK: - requestCloseTab (⇧⌘W, and the strip's ✕)

    func testClosingAOnePaneTabDoesNotAsk() throws {
        let store = store([1, 2])
        let first = try tab(store, 0)

        XCTAssertEqual(store.requestCloseTab(first.id), .closed)

        XCTAssertNil(store.pendingDestruction)
        XCTAssertEqual(terminals(store), [2])
    }

    func testClosingASplitTabAsksFirst() throws {
        let store = store([1, 3])
        try split(store, 0, with: 2)
        let tab = try tab(store, 0)

        XCTAssertEqual(store.requestCloseTab(tab.id), .confirming)

        XCTAssertEqual(store.pendingDestruction, .closeTab(tab.id, paneCount: 2))
        XCTAssertEqual(terminals(store), [1, 2, 3], "nothing closes before the answer")
        XCTAssertEqual(store.pendingDestruction?.title, "Close this tab?")
        XCTAssertEqual(store.pendingDestruction?.confirmTitle, "Close Tab")
        XCTAssertTrue(
            store.pendingDestruction?.message.contains("2 terminals") == true,
            "the dialog has to say how many it is about to take")
    }

    /// The message counts the tab's panes, not the number two.
    func testTheDialogCountsEveryPaneInTheTab() throws {
        let store = store([1, 9])
        try split(store, 0, with: 2)
        try split(store, 0, with: 3)
        let tab = try tab(store, 0)
        XCTAssertEqual(tab.panes.count, 3, "the premise")

        XCTAssertEqual(store.requestCloseTab(tab.id), .confirming)

        XCTAssertEqual(store.pendingDestruction, .closeTab(tab.id, paneCount: 3))
        XCTAssertTrue(
            store.pendingDestruction?.message.contains("3 terminals") == true,
            "the dialog said the wrong number: \(store.pendingDestruction?.message ?? "")")
    }

    func testConfirmingClosesEveryPaneInTheTab() throws {
        let store = store([1, 3])
        try split(store, 0, with: 2)
        let tab = try tab(store, 0)
        store.requestCloseTab(tab.id)

        store.confirmPendingDestruction()

        XCTAssertNil(store.pendingDestruction)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(terminals(store), [3])
    }

    /// The overload that takes the value, which is the one the dialog uses:
    /// SwiftUI writes `isPresented = false` as it dismisses, and that write
    /// runs `cancelPendingDestruction` — so a confirm button reading the slot
    /// back would find it empty. Here the slot is emptied *first*, on purpose.
    func testConfirmingUsesTheValueItWasHandedNotTheSlot() throws {
        let store = store([1, 3])
        try split(store, 0, with: 2)
        let tab = try tab(store, 0)
        store.requestCloseTab(tab.id)
        let pending = try XCTUnwrap(store.pendingDestruction)

        store.cancelPendingDestruction()
        XCTAssertNil(store.pendingDestruction)
        store.confirmPendingDestruction(pending)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(terminals(store), [3])
    }

    func testCancellingLeavesEverything() throws {
        let store = store([1, 3])
        try split(store, 0, with: 2)
        let tab = try tab(store, 0)
        store.requestCloseTab(tab.id)

        store.cancelPendingDestruction()

        XCTAssertNil(store.pendingDestruction)
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(try self.tab(store, 0).id, tab.id)
        XCTAssertEqual(terminals(store), [1, 2, 3])
        XCTAssertTrue(store.closing.isEmpty)
    }

    /// Confirming with nothing pending is not a way to close the front tab.
    func testConfirmingNothingDoesNothing() {
        let store = store([1, 2])
        store.confirmPendingDestruction()
        XCTAssertEqual(store.tabs.count, 2)
    }

    /// The strip's ✕ is on a specific tab, and it is drawn on hover over
    /// *inactive* ones too — so acting on the selection instead of the
    /// argument would close the wrong tab, and move the window while doing it.
    func testClosingABackgroundTabLeavesTheSelectionAlone() throws {
        let store = store([1, 2, 3])
        let first = try tab(store, 0)
        let third = try tab(store, 2)
        store.selectedTabID = first.id

        XCTAssertEqual(store.requestCloseTab(third.id), .closed)

        XCTAssertEqual(terminals(store), [1, 2])
        XCTAssertEqual(store.selectedTabID, first.id, "closing a background tab moved the window")
    }

    /// ⇧⌘W and ⌘W agree about the window's last tab: it closes the window, and
    /// like ⌘W it kills nothing. Before, one chord closed the window and left
    /// the shell running while the other hung the shell up and left an empty
    /// window — opposite answers to both halves, one modifier apart.
    func testTheWindowsLastTabClosesTheWindowAndKillsNothing() throws {
        let store = store([1])
        let tab = try tab(store, 0)

        XCTAssertEqual(store.requestCloseTab(tab.id), .closeWindow)

        XCTAssertEqual(store.tabs.count, 1, "the tab was torn down under the closing window")
        XCTAssertTrue(store.closing.isEmpty, "closing the window hung up the terminal")
        XCTAssertNil(store.pendingDestruction)
    }

    /// Even split. Closing the window destroys nothing, so there is nothing to
    /// confirm — which is why this outranks the pane-count check.
    func testTheWindowsLastTabClosesTheWindowEvenWhenSplit() throws {
        let store = store([1])
        try split(store, 0, with: 2)
        let tab = try tab(store, 0)

        XCTAssertEqual(store.requestCloseTab(tab.id), .closeWindow)

        XCTAssertNil(store.pendingDestruction, "closing a window is not worth a dialog")
        XCTAssertEqual(terminals(store), [1, 2])
        XCTAssertTrue(store.closing.isEmpty)
    }

    /// A tab in another session still counts: the window is holding it, and
    /// closing the window would take it too.
    func testATabInAnotherSessionStopsTheWindowFromClosing() throws {
        let store = twoSessionStore()
        let front = try XCTUnwrap(store.selectedTab)

        XCTAssertEqual(store.requestCloseTab(front.id), .closed)

        XCTAssertEqual(terminals(store), [2])
    }

    func testClosingAnUnknownTabIsNotAWindowClose() {
        let store = store([1, 2])
        XCTAssertEqual(store.requestCloseTab(UUID()), .closed)
        XCTAssertEqual(store.tabs.count, 2)
    }

    /// The closed panes stay closed: the server still lists their terminals for
    /// a moment, and the reconcile must not put the tab back.
    func testAConfirmedCloseIsNotResurrectedByTheNextList() throws {
        let store = store([1, 2])
        try split(store, 0, with: 3)
        store.host(Self.local)?.terminals = [terminal(1), terminal(2), terminal(3)]
        store.host(Self.local)?.sessions = [
            SessionSummary(id: 1, name: "s", terminals: [1, 2, 3])
        ]
        let tab = try tab(store, 0)

        store.requestCloseTab(tab.id)
        store.confirmPendingDestruction()
        XCTAssertEqual(terminals(store), [2])

        // The server has not caught up yet.
        store.reconcileTabs()
        XCTAssertEqual(terminals(store), [2])
    }

    /// Both terminals of a split can exit on their own while the dialog is up.
    /// Asking about a tab that is no longer on screen is a lie, even though
    /// confirming it would have been harmless.
    func testADialogAboutAVanishedTabIsTakenDown() throws {
        let store = store([1, 2])
        try split(store, 0, with: 3)
        store.host(Self.local)?.terminals = [terminal(1), terminal(2), terminal(3)]
        let tab = try tab(store, 0)
        store.requestCloseTab(tab.id)
        XCTAssertNotNil(store.pendingDestruction)

        // 1 and 3 exited on their own.
        store.host(Self.local)?.terminals = [terminal(2)]
        store.reconcileTabs()

        XCTAssertNil(store.pendingDestruction, "the dialog outlived the tab it names")
        XCTAssertEqual(terminals(store), [2])
    }
}
