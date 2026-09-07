//  TabOrderTests.swift
//  Reordering the tab strip, and the reduce-motion gate every animation in the
//  app goes through.
//
//  Tab order is client state: the server has no opinion about it (issue #38),
//  so `moveTab` is the whole of the feature and the drag gesture over it is
//  just a way to call it. That is why the model op is tested and the gesture
//  is not — the same reason `TabReconcileTests` drives the store rather than a
//  socket.

import AppKit
import IllogicalProtocol
import SwiftUI
import XCTest

@MainActor
final class TabOrderTests: XCTestCase {
    private static let local = ServerHost.local(socketPath: "/tmp/illogical-order-test.sock")

    /// Nothing here reaches the filesystem or the developer's real preferences.
    private final class InMemoryDefaults: HostDefaults {
        private var values: [String: Data] = [:]
        func data(forKey defaultName: String) -> Data? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) {
            values[defaultName] = value as? Data
        }
    }

    private func terminal(_ id: UInt64, session: UInt64) -> TerminalSummary {
        TerminalSummary(
            id: id, session: session, name: "t\(id)", command: "/bin/zsh", cwd: "/",
            cols: 80, rows: 24, residency: .live, attached: 0, ptyReadIdleNanoseconds: 0)
    }

    /// A store with one tab per terminal, in the order given.
    ///
    /// `sessions` maps a session id to its terminal ids, so a two-session store
    /// — the case `moveTab` refuses to move across — is one literal.
    private func store(_ sessions: KeyValuePairs<UInt64, [UInt64]>) -> SessionStore {
        let store = SessionStore(hosts: [Self.local], defaults: InMemoryDefaults())
        guard let connection = store.host(Self.local) else {
            XCTFail("no such host")
            return store
        }
        connection.sessions = sessions.map {
            SessionSummary(id: $0.key, name: "s\($0.key)", terminals: $0.value)
        }
        connection.terminals = sessions.flatMap { session, ids in
            ids.map { terminal($0, session: session) }
        }
        store.reconcileTabs()
        return store
    }

    /// The terminal behind each tab, in strip order. Tabs have UUID ids, so
    /// this is how an order is asserted readably.
    private func order(_ store: SessionStore) -> [UInt64] {
        store.tabs.compactMap { $0.panes.first?.terminal.terminal }
    }

    private func visibleOrder(_ store: SessionStore) -> [UInt64] {
        store.visibleTabs.compactMap { $0.panes.first?.terminal.terminal }
    }

    /// The tab showing terminal `id`.
    private func tab(_ store: SessionStore, _ id: UInt64) -> TabLayout.ID {
        store.tabs.first { $0.panes.contains { $0.terminal.terminal == id } }!.id
    }

    // MARK: - moveTab(_:before:)

    func testMoveToTheFrontOfTheStrip() {
        let store = store([1: [1, 2, 3]])
        store.moveTab(tab(store, 3), before: tab(store, 1))
        XCTAssertEqual(order(store), [3, 1, 2])
    }

    /// The interesting direction: moving right, the tab has to land *before*
    /// the target, which is one slot short of the target's old index once the
    /// tab has been taken out of the array. Getting this wrong is off-by-one
    /// in exactly one direction, so both are asserted.
    func testMoveRightLandsBeforeTheTarget() {
        let store = store([1: [1, 2, 3]])
        store.moveTab(tab(store, 1), before: tab(store, 3))
        XCTAssertEqual(order(store), [2, 1, 3])
    }

    func testMoveBeforeItselfIsANoOp() {
        let store = store([1: [1, 2, 3]])
        let second = tab(store, 2)
        store.moveTab(second, before: second)
        XCTAssertEqual(order(store), [1, 2, 3])
    }

    /// Already immediately before the target: the move is legal and changes
    /// nothing, rather than shuffling the tab one slot.
    func testMoveBeforeTheNextTabIsANoOp() {
        let store = store([1: [1, 2, 3]])
        store.moveTab(tab(store, 1), before: tab(store, 2))
        XCTAssertEqual(order(store), [1, 2, 3])
    }

    func testNilTargetAppends() {
        let store = store([1: [1, 2, 3]])
        store.moveTab(tab(store, 1), before: nil)
        XCTAssertEqual(order(store), [2, 3, 1])
    }

    func testNilTargetOnTheLastTabIsANoOp() {
        let store = store([1: [1, 2, 3]])
        store.moveTab(tab(store, 3), before: nil)
        XCTAssertEqual(order(store), [1, 2, 3])
    }

    func testAnUnknownTabIsIgnored() {
        let store = store([1: [1, 2]])
        store.moveTab(UUID(), before: tab(store, 1))
        store.moveTab(tab(store, 1), before: UUID())
        XCTAssertEqual(order(store), [1, 2])
    }

    /// The strip only ever draws one session's tabs, so this is a drop the UI
    /// cannot produce — and the model refuses it rather than producing an
    /// order no strip could show.
    func testACrossSessionMoveIsRefused() {
        let store = store([1: [1, 2], 2: [3, 4]])
        store.moveTab(tab(store, 3), before: tab(store, 1))
        XCTAssertEqual(order(store), [1, 2, 3, 4])
    }

    /// `before: nil` means the end of *this session's* run, not the end of the
    /// array: another session's tabs must not be jumped over.
    func testNilTargetStopsAtTheEndOfItsOwnSession() {
        let store = store([1: [1, 2], 2: [3, 4]])
        store.moveTab(tab(store, 1), before: nil)
        XCTAssertEqual(order(store), [2, 1, 3, 4])
        XCTAssertEqual(visibleOrder(store), [2, 1])
    }

    /// Dragging a tab rearranges the strip; it does not switch to what was
    /// dragged, and it does not lose where you were either.
    func testSelectionSurvivesAMove() {
        let store = store([1: [1, 2, 3]])
        let second = tab(store, 2)
        store.selectedTabID = second
        store.moveTab(tab(store, 3), before: tab(store, 1))
        XCTAssertEqual(store.selectedTabID, second)
        XCTAssertEqual(order(store), [3, 1, 2])
    }

    // MARK: - moveTab(_:onto:)

    /// A drop is "take that slot", which is not the same as "go before that
    /// tab" when the tab is travelling right: dropping 1 onto 3 has to leave 1
    /// where 3 was, or the tab lands one slot short of the pointer.
    func testDropOntoASlotTravellingRight() {
        let store = store([1: [1, 2, 3]])
        store.moveTab(tab(store, 1), onto: tab(store, 3))
        XCTAssertEqual(order(store), [2, 3, 1])
    }

    func testDropOntoASlotTravellingLeft() {
        let store = store([1: [1, 2, 3]])
        store.moveTab(tab(store, 3), onto: tab(store, 1))
        XCTAssertEqual(order(store), [3, 1, 2])
    }

    func testDropOntoItselfIsANoOp() {
        let store = store([1: [1, 2, 3]])
        let second = tab(store, 2)
        store.moveTab(second, onto: second)
        XCTAssertEqual(order(store), [1, 2, 3])
    }

    /// Travelling right onto the last tab of a session whose tabs are followed
    /// by another session's: "after the target" has to mean the end of this
    /// session's run, not the slot in front of the next session's first tab —
    /// which `moveTab(_:before:)` would refuse outright.
    func testDropOntoTheLastTabOfASessionWithAnotherSessionBehindIt() {
        let store = store([1: [1, 2], 2: [3]])
        store.moveTab(tab(store, 1), onto: tab(store, 2))
        XCTAssertEqual(order(store), [2, 1, 3])
        XCTAssertEqual(visibleOrder(store), [2, 1])
    }

    func testDropAcrossSessionsIsRefused() {
        let store = store([1: [1, 2], 2: [3, 4]])
        store.moveTab(tab(store, 1), onto: tab(store, 4))
        XCTAssertEqual(order(store), [1, 2, 3, 4])
    }

    // MARK: - Drag geometry

    /// The slot arithmetic behind drag-to-reorder. The gesture that feeds it
    /// cannot be simulated, so this is the part worth holding: the rounding,
    /// the clamps, and the do-nothing case.
    private func dropIndex(from: Int, _ translation: CGFloat, count: Int = 4) -> Int {
        TabStrip.dropIndex(from: from, translation: translation, slotWidth: 200, count: count)
    }

    func testASmallDragStaysInItsSlot() {
        XCTAssertEqual(dropIndex(from: 1, 0), 1)
        XCTAssertEqual(dropIndex(from: 1, 99), 1)
        XCTAssertEqual(dropIndex(from: 1, -99), 1)
    }

    /// Half a slot is the tipping point: past it the tab has visibly passed its
    /// neighbour, and that is when it should take its place.
    func testPastHalfASlotTakesTheNextOne() {
        XCTAssertEqual(dropIndex(from: 1, 100), 2)
        XCTAssertEqual(dropIndex(from: 1, -100), 0)
        XCTAssertEqual(dropIndex(from: 0, 250), 1)
        XCTAssertEqual(dropIndex(from: 0, 401), 2)
    }

    /// Dragging off the end parks the tab at the end rather than doing nothing,
    /// which is what an unclamped index would become once `moveTab` failed to
    /// find a tab at it.
    func testDraggingOffTheEndClamps() {
        XCTAssertEqual(dropIndex(from: 0, 5000), 3)
        XCTAssertEqual(dropIndex(from: 3, -5000), 0)
    }

    func testDegenerateStripsAreLeftAlone() {
        XCTAssertEqual(TabStrip.dropIndex(from: 0, translation: 500, slotWidth: 200, count: 0), 0)
        XCTAssertEqual(TabStrip.dropIndex(from: 2, translation: 500, slotWidth: 0, count: 4), 2)
        XCTAssertEqual(TabStrip.dropIndex(from: 2, translation: .nan, slotWidth: 200, count: 4), 2)
    }

    // MARK: - Drag plumbing

    /// The one line of the drag *plumbing* a test can hold, and it is worth
    /// being plain about how little that is.
    ///
    /// The arithmetic above was already right when drag-to-reorder did nothing
    /// at all: the toolbar is an `NSTitlebarAccessoryViewController`, every view
    /// SwiftUI puts in one answers `mouseDownCanMoveWindow` with `true`, and so
    /// AppKit's window drag took the mouse-down before the gesture could start.
    /// `ClaimsMouseDown` is the fix and this is its whole contract.
    ///
    /// What this does *not* cover: that the modifier is actually applied to the
    /// tab slots, the session button and `+`; that AppKit really subtracts the
    /// view's frame from the title bar's draggable region; or that the buttons
    /// drawn over it still get their clicks. None of that exists without a
    /// window on a screen, and all of it was checked by driving the running app
    /// with `CGEvent`s and reading geometry back through the accessibility API.
    /// A test that asserted the reorder itself would have passed with the bug
    /// present, which is the trap this branch exists to get out of.
    func testATabSlotIsNotWindowChrome() {
        XCTAssertFalse(ClaimsMouseDown.BackingView(frame: .zero).mouseDownCanMoveWindow)
        // Against the default, so the assertion above is known to be saying
        // something: a plain view in a hosting view is what drags the window.
        XCTAssertTrue(NSView(frame: .zero).mouseDownCanMoveWindow)
    }

    // MARK: - The reduce-motion gate

    /// The animation specs themselves are not unit-testable — a duration is a
    /// number SwiftUI keeps to itself. The gate is, and it is the part that
    /// matters: every animated surface in the app goes through
    /// `animation(reduceMotion:)`, so this is "Reduce Motion turns the chrome
    /// still" asserted once instead of surveyed across a dozen views.
    func testReduceMotionRemovesEveryAnimation() {
        for motion in Self.everyMotion {
            XCTAssertNil(motion.animation(reduceMotion: true))
            XCTAssertNotNil(motion.animation(reduceMotion: false))
        }
    }

    /// Reduce Motion is a crossfade and nothing else: a scale or a slide moves
    /// something, which is the thing the setting asks us not to do. Asserted on
    /// `entrance(reduceMotion:)` rather than on the `AnyTransition` it builds,
    /// because `AnyTransition` is opaque and comparing two of them compares
    /// nothing — which is exactly why `Entrance.transition` carries no gate of
    /// its own and `Motion`'s stored entrance is private. There is no
    /// expression in the app that reaches a transition around this function.
    func testReduceMotionLeavesOnlyACrossfade() {
        for motion in Self.everyMotion {
            XCTAssertEqual(motion.entrance(reduceMotion: true), .fade)
        }
    }

    /// The vocabulary itself, so a stray edit shows up in a diff rather than
    /// only on screen. Every field of every entry, each against a *literal*: an
    /// assertion that reads a value back out of the object it came from pins
    /// nothing, which is how three of these six went unheld in the first draft.
    /// These are the numbers and curves `docs/CLIENT.md` publishes.
    func testTheVocabularyIsWhatItSaysItIs() {
        let expected: [(Motion, Double, Motion.Curve, Motion.Entrance)] = [
            (.menu, 0.12, .easeOut, .menu),
            (.tabs, 0.18, .snappy, .fade),
            (.splits, 0.16, .easeOut, .fade),
            (.banner, 0.2, .easeOut, .fromTop),
            (.screen, 0.15, .easeInOut, .fade),
            (.badge, 0.12, .easeOut, .fade),
        ]
        XCTAssertEqual(expected.count, Self.everyMotion.count)
        for (motion, duration, curve, entrance) in expected {
            XCTAssertEqual(motion.duration, duration)
            XCTAssertEqual(motion.curve, curve)
            XCTAssertEqual(motion.entrance(reduceMotion: false), entrance)
        }
    }

    /// `Motion.run` is what `SessionStore` animates its split-tree mutations
    /// with. `withAnimation` cannot be observed after the fact — there is no
    /// public read of the ambient transaction outside a view update — so the
    /// *choice* of animation is pinned by `animation(reduceMotion:)` above and
    /// `run` is one expression over it. What is held here is the rest: the body
    /// runs, exactly once, and its value comes back, under either setting. A
    /// `run` that quietly stopped calling its closure would take every split,
    /// close and zoom in the app with it.
    func testRunCallsItsBodyExactlyOnceAndReturnsIt() {
        for reduceMotion in [true, false] {
            var calls = 0
            let result = Motion.splits.run(reduceMotion: reduceMotion) { () -> Int in
                calls += 1
                return 7
            }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(result, 7)
        }
    }

    /// Every entry in the vocabulary. A test that iterates a list it also
    /// writes is only as complete as the list, so `testTheVocabularyIsWhatIt…`
    /// asserts this count against its own table.
    private static let everyMotion: [Motion] = [
        .menu, .tabs, .splits, .banner, .screen, .badge,
    ]
}
