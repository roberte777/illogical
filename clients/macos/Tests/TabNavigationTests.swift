//  TabNavigationTests.swift
//  ⇧⌘] , ⇧⌘[ , ⌘1–⌘9 and ⌃⇥ , as store operations and one matcher.
//
//  The chords are menu items in `IllogicalApp`, but everything they decide is
//  here: which tabs are reachable, what wrapping does at the ends, and that
//  ⌘9 means the last tab rather than the ninth. All of it scoped to
//  `visibleTabs` — the strip shows one session at a time, and a keystroke must
//  not jump the window to another machine.
//
//  ⌃⇥ is the one chord no menu item holds, so its own half — which events
//  belong to it — is tested beside them at the end.

import AppKit
import IllogicalProtocol
import XCTest

@MainActor
final class TabNavigationTests: XCTestCase {
    private static let local = ServerHost.local(socketPath: "/tmp/illogical-nav-test.sock")

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

    private func store(_ ids: [UInt64]) -> SessionStore {
        let store = SessionStore(hosts: [Self.local], defaults: InMemoryDefaults())
        guard let host = store.host(Self.local) else { return store }
        host.sessions = [SessionSummary(id: 1, name: "s", terminals: ids)]
        host.terminals = ids.map { terminal($0) }
        store.reconcileTabs()
        return store
    }

    /// One tab in session 1, two in session 2.
    private func twoSessionStore() -> SessionStore {
        let store = SessionStore(hosts: [Self.local], defaults: InMemoryDefaults())
        guard let host = store.host(Self.local) else { return store }
        host.sessions = [
            SessionSummary(id: 1, name: "a", terminals: [1]),
            SessionSummary(id: 2, name: "b", terminals: [2, 3]),
        ]
        host.terminals = [
            terminal(1, session: 1), terminal(2, session: 2), terminal(3, session: 2),
        ]
        store.reconcileTabs()
        return store
    }

    /// The terminal behind the front tab, which is what a user sees change.
    private func front(_ store: SessionStore) -> UInt64? {
        store.selectedRef?.terminal
    }

    /// A tab by position, as a failure rather than a trap: an unguarded
    /// `store.tabs[1]` on a shorter list kills the whole xctest process and
    /// takes every test still to run in the bundle with it.
    private func tab(_ store: SessionStore, _ index: Int) throws -> TabLayout {
        try XCTUnwrap(
            store.tabs.indices.contains(index) ? store.tabs[index] : nil,
            "no tab at \(index): the store holds \(store.tabs.count)")
    }

    func testNextAndPreviousWalkTheStrip() {
        let store = store([1, 2, 3])
        XCTAssertEqual(front(store), 1)

        store.selectNextTab()
        XCTAssertEqual(front(store), 2)
        store.selectNextTab()
        XCTAssertEqual(front(store), 3)

        store.selectPreviousTab()
        XCTAssertEqual(front(store), 2)
    }

    /// Both ends wrap, the way Terminal.app's ⇧⌘] does.
    func testNextAndPreviousWrap() throws {
        let store = store([1, 2, 3])
        store.selectedTabID = try tab(store, 2).id

        store.selectNextTab()
        XCTAssertEqual(front(store), 1)

        store.selectPreviousTab()
        XCTAssertEqual(front(store), 3)
    }

    func testASingleTabHasNowhereToGo() {
        let store = store([1])
        store.selectNextTab()
        XCTAssertEqual(front(store), 1)
        store.selectPreviousTab()
        XCTAssertEqual(front(store), 1)
    }

    func testNoTabsAtAllIsNotACrash() {
        let store = store([])
        store.selectNextTab()
        store.selectPreviousTab()
        store.selectTab(at: 1)
        XCTAssertNil(store.selectedTabID)
    }

    /// The strip shows one session, so ⇧⌘] must stay inside it. Walking
    /// `tabs` instead would move the window to another session — and, with two
    /// machines, to another machine.
    func testWalkingIsScopedToTheSessionInFront() throws {
        let store = twoSessionStore()
        // Sit in session 2, which has two tabs; session 1's is elsewhere.
        store.selectedTabID = try tab(store, 1).id
        XCTAssertEqual(store.visibleTabs.count, 2)

        store.selectNextTab()
        XCTAssertEqual(front(store), 3)
        store.selectNextTab()
        XCTAssertEqual(front(store), 2, "wrapped inside the session")

        XCTAssertEqual(store.selectedSession?.session, 2)
    }

    /// A session with one tab has nothing to walk to, even with tabs behind it
    /// in another session.
    func testASingleVisibleTabDoesNotWalkIntoAnotherSession() throws {
        let store = twoSessionStore()
        store.selectedTabID = try tab(store, 0).id
        XCTAssertEqual(store.visibleTabs.count, 1)

        store.selectNextTab()
        XCTAssertEqual(front(store), 1)
        XCTAssertEqual(store.selectedSession?.session, 1)
    }

    // MARK: - ⌘1 … ⌘9

    func testSelectTabIsOneBased() {
        let store = store([1, 2, 3])

        store.selectTab(at: 2)
        XCTAssertEqual(front(store), 2)
        store.selectTab(at: 1)
        XCTAssertEqual(front(store), 1)
    }

    /// ⌘9 is the *last* tab, not the ninth — the convention iTerm, Ghostty and
    /// every browser share.
    func testNineIsTheLastTab() {
        let store = store([1, 2, 3])
        store.selectTab(at: SessionStore.lastTabIndex)
        XCTAssertEqual(front(store), 3)
    }

    /// Out of range means *nothing happens*, not "clamp to an end". Probed
    /// from tab 2 on purpose: starting on tab 1 and asserting tab 1 passes
    /// just as well against an implementation that clamps onto the first.
    func testAnIndexOutOfRangeDoesNothing() {
        let store = store([1, 2, 3])
        store.selectTab(at: 2)
        XCTAssertEqual(front(store), 2, "the premise")

        store.selectTab(at: 5)
        XCTAssertEqual(front(store), 2, "an index past the end moved the selection")
        store.selectTab(at: 0)
        XCTAssertEqual(front(store), 2, "index zero clamped onto the first tab")
        store.selectTab(at: -1)
        XCTAssertEqual(front(store), 2)
    }

    func testSelectTabIsScopedToTheSessionInFront() throws {
        let store = twoSessionStore()
        store.selectedTabID = try tab(store, 1).id

        store.selectTab(at: 2)
        XCTAssertEqual(front(store), 3, "second tab of the front session, not of the window")
        XCTAssertEqual(store.selectedSession?.session, 2)
    }

    /// What the menu greys out.
    ///
    /// Honesty, not safety: a *disabled* menu item still consumes its key
    /// equivalent — `performKeyEquivalent` reports the chord handled and
    /// simply does not fire — so ⌘5 with two tabs never reaches the terminal
    /// either way. An enabled item that does nothing is just a lie about what
    /// the app can do.
    func testTheMenuKnowsWhichIndexesGoAnywhere() {
        let two = store([1, 2])
        XCTAssertTrue(two.canSelectTab(at: 1))
        XCTAssertTrue(two.canSelectTab(at: 2))
        XCTAssertFalse(two.canSelectTab(at: 3))
        XCTAssertTrue(two.canSelectTab(at: SessionStore.lastTabIndex))

        let empty = store([])
        XCTAssertFalse(empty.canSelectTab(at: 1))
        XCTAssertFalse(empty.canSelectTab(at: SessionStore.lastTabIndex))
    }

    /// And it counts the *visible* tabs. Sitting in a session with one tab
    /// while the window holds another session's, ⌘2 goes nowhere — an item
    /// gated on `tabs` would have been enabled and inert.
    func testTheMenuCountsTheSessionInFrontNotTheWindow() throws {
        let store = twoSessionStore()
        store.selectedTabID = try tab(store, 0).id
        XCTAssertEqual(store.visibleTabs.count, 1)
        XCTAssertEqual(store.tabs.count, 3, "the window holds more than the strip shows")

        XCTAssertTrue(store.canSelectTab(at: 1))
        XCTAssertFalse(store.canSelectTab(at: 2), "⌘2 was offered for another session's tab")
    }

    // MARK: - ⇧⌘K

    func testTogglingTheSessionMenu() {
        let store = store([1])
        let wasOpen = store.sessionMenuOpen

        store.toggleSessionMenu()
        XCTAssertEqual(store.sessionMenuOpen, !wasOpen)
        store.toggleSessionMenu()
        XCTAssertEqual(store.sessionMenuOpen, wasOpen)
    }

    /// The counter `TerminalSurface` keys off to re-assert first responder.
    /// Its value means nothing; that it *changes* is the whole mechanism.
    func testAskingForTheKeyboardBackChangesTheFocusGeneration() {
        let store = store([1])
        let before = store.focusGeneration
        store.focusTerminal()
        XCTAssertNotEqual(store.focusGeneration, before)
    }

    // MARK: - ⌃⇥
    //
    // The monitor itself needs a window and cannot be driven from here; the
    // decision it makes can. Every chord `TabCycle.direction` wrongly claims
    // is a keystroke that stops reaching the terminal, so the negatives below
    // matter more than the two positives.

    private func direction(
        _ mods: NSEvent.ModifierFlags, keyCode: UInt16 = TabCycle.tabKeyCode
    ) -> TabCycle.Direction? {
        TabCycle.direction(keyCode: keyCode, modifiers: mods)
    }

    func testControlTabCyclesForwardsAndControlShiftTabBack() {
        XCTAssertEqual(direction(.control), .next)
        XCTAssertEqual(direction([.control, .shift]), .previous)
    }

    /// Bare ⇥ is completion in every shell, and ⇧⇥ is the way back out of it.
    /// Neither is ours.
    func testTabWithoutControlBelongsToTheTerminal() {
        XCTAssertNil(direction([]))
        XCTAssertNil(direction(.shift))
    }

    /// ⌃ **and nothing else**. A `contains(.control)` test would have eaten
    /// all three of these.
    func testControlWithAnotherModifierIsNotTheChord() {
        XCTAssertNil(direction([.control, .option]))
        XCTAssertNil(direction([.control, .command]))
        XCTAssertNil(direction([.control, .shift, .option]))
    }

    /// The other half of "and nothing else": ⌃ on any other key is the
    /// program's. ⌃C is the one that would be missed.
    func testControlOnAnotherKeyIsNotTheChord() {
        XCTAssertNil(direction(.control, keyCode: 8), "⌃C")
        XCTAssertNil(direction(.control, keyCode: 36), "⌃↩")
    }

    /// AppKit sets bits on a real event that are not modifiers a user pressed:
    /// caps lock, and the left/right bit saying which ⌃ it was. Both have to
    /// wash out, or the chord works on one keyboard half and not the other.
    func testTheBitsAppKitAddsDoNotCount() {
        XCTAssertEqual(direction([.control, .capsLock]), .next)
        // `NX_DEVICELCTLKEYMASK` — the left-control device bit, as it arrives
        // alongside `.control` in a live `keyDown`.
        XCTAssertEqual(direction(NSEvent.ModifierFlags(rawValue: 0x04_0001)), .next)
    }

    // MARK: - ⌃⇥'s key-up debt
    //
    // A chord whose press is dropped owes a dropped release. Every other chord
    // in the app carries ⌘, and AppKit delivers no `keyUp` while ⌘ is held, so
    // this bookkeeping exists nowhere else — and under the Kitty protocol a
    // stray release is a real event a program is told about.

    private func down(
        _ mods: NSEvent.ModifierFlags, _ matcher: inout TabCycle.Matcher,
        keyCode: UInt16 = TabCycle.tabKeyCode
    ) -> TabCycle.Claim {
        matcher.claim(isKeyUp: false, keyCode: keyCode, modifiers: mods)
    }

    private func up(
        _ mods: NSEvent.ModifierFlags, _ matcher: inout TabCycle.Matcher,
        keyCode: UInt16 = TabCycle.tabKeyCode
    ) -> TabCycle.Claim {
        matcher.claim(isKeyUp: true, keyCode: keyCode, modifiers: mods)
    }

    /// The release usually carries no ⌃ at all — letting go of the modifier
    /// first is how anyone releases this chord — so it is matched to the press
    /// that was taken, not to its own modifiers.
    func testTheReleaseOfAClaimedChordIsDroppedWhateverItCarries() {
        var matcher = TabCycle.Matcher()
        XCTAssertEqual(down(.control, &matcher), .cycle(.next))
        XCTAssertEqual(up([], &matcher), .drop, "⌃ released before ⇥")
    }

    /// One press, one dropped release. A second release is somebody else's.
    func testOnlyOneReleaseIsOwed() {
        var matcher = TabCycle.Matcher()
        XCTAssertEqual(down([.control, .shift], &matcher), .cycle(.previous))
        XCTAssertEqual(up([], &matcher), .drop)
        XCTAssertEqual(up([], &matcher), .pass)
    }

    /// A held chord repeats: many downs, one up.
    func testARepeatingChordStillOwesOneRelease() {
        var matcher = TabCycle.Matcher()
        XCTAssertEqual(down(.control, &matcher), .cycle(.next))
        XCTAssertEqual(down(.control, &matcher), .cycle(.next))
        XCTAssertEqual(up([], &matcher), .drop)
        XCTAssertEqual(up([], &matcher), .pass)
    }

    /// Bare ⇥ passes through in both halves, or completion would work and its
    /// release would not.
    func testAnUnclaimedTabPassesBothWays() {
        var matcher = TabCycle.Matcher()
        XCTAssertEqual(down([], &matcher), .pass)
        XCTAssertEqual(up([], &matcher), .pass)
    }

    /// The debt cannot outlive the next ordinary ⇥.
    ///
    /// A chord pressed and then ⌘⇥ away leaves the release in another app, so
    /// the debt is never collected. Without the press of a plain ⇥ settling it,
    /// that stranded flag would eat *its* release — a program under the Kitty
    /// protocol told about a press whose release never comes.
    func testADebtStrandedByAReleaseDeliveredElsewhereIsSettledByTheNextTab() {
        var matcher = TabCycle.Matcher()
        XCTAssertEqual(down(.control, &matcher), .cycle(.next))
        // The release went to whatever the user switched to. Back here, an
        // ordinary ⇥ is typed.
        XCTAssertEqual(down([], &matcher), .pass)
        XCTAssertEqual(up([], &matcher), .pass, "the stranded debt ate a real release")
    }

    /// And a release of some *other* key never settles it — the debt is a ⇥.
    func testAnotherKeysReleaseIsNotTheOneOwed() {
        var matcher = TabCycle.Matcher()
        XCTAssertEqual(down(.control, &matcher), .cycle(.next))
        XCTAssertEqual(up([], &matcher, keyCode: 8), .pass, "⌃C's release")
        XCTAssertEqual(up([], &matcher), .drop)
    }
}
