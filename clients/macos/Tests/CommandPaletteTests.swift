//  CommandPaletteTests.swift
//  The command table, and the two-stage panel over it.
//
//  Three things are worth pinning here and none of them needs a window.
//
//  The **table** is the app's one list of verbs, and the whole reason it
//  exists is that two hand-written lists drift. So the tests hold it against
//  `CommandID.allCases`, and they read the chords a person sees out of the very
//  `KeyboardShortcut` the menu item applies rather than out of a second string.
//
//  The **state machine** is a pair of `didSet`s, four methods on the store and
//  two repairs `init` makes by hand. It decides which overlay is up, whether a
//  command runs or asks for an argument first, and what a filter means — every
//  one of which used to be the kind of thing a view was trusted to remember.
//  The two in `init` are there because a `didSet` does not run for a property's
//  initial value, which is exactly why they also needed a seam to be tested
//  through: the launch overlay state is an argument, and an assignment from a
//  test would run the observers these stand in for.
//
//  The **row rules** are the four pure functions in `PaletteKeys`. Neither the
//  monitor around two of them nor the hover callback behind the fourth can be
//  driven from a unit test, exactly as `EscapeKey`'s and `TabCycleKey`'s
//  cannot, but the decisions can: every key wrongly claimed is a keystroke the
//  search field stops receiving, an arrow that lands on a dimmed row is a
//  Return that does nothing, and a hover that counts when the mouse has not
//  moved is a highlight the keyboard cannot keep.
//
//  Driven without a socket throughout, and deliberately without dialling one
//  either. `CurrentHostTests` records the regression this is guarding against
//  in as many words — two suites once spawned a real `ssh build-box` per run —
//  so the one test that reaches `addHost` arranges for every destination it
//  could commit to be a machine the store already holds, marked connected,
//  which is the branch that returns without connecting anything. *Every* one:
//  arranging only the destination the correct code path commits leaves the
//  suite dialling the moment the code under test regresses, which is the one
//  run where nobody is watching.

import Foundation
import IllogicalProtocol
import XCTest

@MainActor
final class CommandPaletteTests: XCTestCase {
    private static let local = ServerHost.local(socketPath: "/tmp/illogical-palette.sock")
    private static let remote = ServerHost.ssh(destination: "build-box")
    /// A third machine, for the lists that leave one out: Switch Host does not
    /// offer the machine the window is already on, so two hosts make a list of
    /// one and there is nothing left to filter or to arrow through.
    private static let otherRemote = ServerHost.ssh(destination: "web-01")

    /// Somewhere in memory to read and write. The same shape
    /// `CurrentHostTests` uses, and here for the same reason: a suite that
    /// wrote through to `UserDefaults.standard` would scribble remembered
    /// hosts onto the developer's own machine.
    private final class InMemoryDefaults: HostDefaults {
        private var values: [String: Data] = [:]
        func data(forKey defaultName: String) -> Data? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) {
            values[defaultName] = value as? Data
        }
    }

    private typealias Listing = (id: UInt64, name: String, terminals: [UInt64])

    /// A store with the hosts named and nothing on any of them, dialling
    /// nothing: the launcher is injected for the same reason the defaults are,
    /// since a `.local` host that reached `connect()` with the real one would
    /// start a daemon.
    private func emptyStore(_ hosts: [ServerHost] = [local]) -> SessionStore {
        SessionStore(
            hosts: hosts, defaults: InMemoryDefaults(),
            launcher: RecordingLauncher(.succeedSilently))
    }

    /// What a `session_list` frame does, without a socket. The status is part
    /// of it: `HostConnection` sets `.connected` on the list and calls
    /// `onListChanged` on the next line.
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

    private func command(_ id: CommandID) -> Command { Commands.command(id) }

    // MARK: - The table

    /// The invariant the whole file rests on. `Commands.command(_:)` traps on a
    /// hole rather than handing back a placeholder, and `byID` traps on a
    /// duplicate, so this is what stops either reaching a build.
    func testEveryCommandAppearsExactlyOnceInTheRegistry() {
        XCTAssertEqual(Commands.all.count, CommandID.allCases.count)
        XCTAssertEqual(Set(Commands.all.map(\.id)), Set(CommandID.allCases))
        for id in CommandID.allCases {
            XCTAssertEqual(command(id).id, id, "the table hands back the wrong entry for \(id)")
        }
    }

    /// A chord is written down once — in the table, as the thing the menu item
    /// applies — and what the palette draws is derived from it. So this is not
    /// really about the glyphs: it is about there being no second string to
    /// forget when a chord moves.
    func testShortcutDisplayMatchesTheChordTheMenuClaims() throws {
        func chord(_ id: CommandID) throws -> String {
            ShortcutDisplay.string(try XCTUnwrap(command(id).shortcut, "\(id) has no chord"))
        }

        XCTAssertEqual(try chord(.commandPalette), "⇧⌘P")
        XCTAssertEqual(try chord(.newTerminal), "⌘T")
        XCTAssertEqual(try chord(.newSession), "⇧⌘N")
        // The named keys as their glyphs, which is the half a plain
        // `uppercased()` would have drawn as an unprintable character.
        XCTAssertEqual(try chord(.toggleZoom), "⇧⌘↩")
        XCTAssertEqual(try chord(.focusPaneLeft), "⌥⌘←")
        XCTAssertEqual(try chord(.focusPaneBelow), "⌥⌘↓")
        // A punctuation key has no upper case to be shifted into.
        XCTAssertEqual(try chord(.showPreviousTab), "⇧⌘[")
        XCTAssertEqual(try chord(.showNextTab), "⇧⌘]")

        // The two host verbs are chord-less on purpose, on the rule Rename and
        // Delete Session already state.
        XCTAssertNil(command(.addRemoteHost).shortcut)
        XCTAssertNil(command(.forgetHost).shortcut)
    }

    /// Every tooltip in the app that names a chord now takes it from the table
    /// — the session button, the tab ✕, the toolbar's ＋, both split buttons
    /// and the zoom button in a pane header, and the search bar's two step
    /// arrows. The one over the session button had drifted twice: `⌘⇧K`, in
    /// the wrong modifier order *and* bound to nothing at all, which is what a
    /// second place to write a chord down buys you.
    ///
    /// The pane header and the search bar are the far ones, and the reason for
    /// the second form: those controls keep their own shorter nouns and take
    /// only the chord from here.
    func testHelpTextDerivesFromTheTable() {
        let store = emptyStore()

        XCTAssertEqual(Commands.help(.changeSession, store), "Change Session (⌘K)")
        XCTAssertEqual(Commands.help(.newTerminal, store), "New Terminal (⌘T)")
        XCTAssertEqual(Commands.help(.closeTab, store), "Close Tab (⇧⌘W)")
        XCTAssertEqual(Commands.help(.splitRight, store), "Split Right (⌘D)")
        XCTAssertEqual(Commands.help(.splitDown, store), "Split Down (⇧⌘D)")

        // The local-noun form: the surface's wording, the table's chord.
        XCTAssertEqual(Commands.help(.toggleZoom, titled: "Unzoom"), "Unzoom (⇧⌘↩)")
        XCTAssertEqual(
            Commands.help(.findPrevious, titled: "Previous Match"), "Previous Match (⇧⌘G)")
        XCTAssertEqual(Commands.help(.findNext, titled: "Next Match"), "Next Match (⌘G)")

        // A command with no chord is its bare title, rather than a title with
        // an empty pair of brackets after it...
        XCTAssertEqual(Commands.help(.addRemoteHost, store), "Add Remote Host…")
        // ...and the second form degrades the same way, which is the whole
        // reason it is a `help` rather than a raw chord accessor: a nil branch
        // handed to every call site is a nil branch each of them gets to spell
        // differently.
        XCTAssertEqual(Commands.help(.addRemoteHost, titled: "Add Host"), "Add Host")
    }

    /// The one title that moves, and the predicate under it. An unsplit tab has
    /// no pane to zoom, and the menu item said "Zoom Pane" and did nothing.
    func testZoomPaneTitleFollowsTheStore() throws {
        let store = emptyStore()
        list(store, [(1, "work", [1])])

        XCTAssertEqual(command(.toggleZoom).title(store), "Zoom Pane")
        XCTAssertFalse(
            command(.toggleZoom).isEnabled(store), "an unsplit tab was offered a zoom")

        // Split by hand: the real path is a round trip to a server, and what is
        // under test here is a title rather than a protocol.
        let index = try XCTUnwrap(store.tabs.firstIndex { $0.id == store.selectedTabID })
        let pane = Pane(terminal: TerminalRef(host: Self.local, terminal: 2))
        store.tabs[index].root = store.tabs[index].root.splitting(
            store.tabs[index].focused, with: pane, direction: .columns)

        XCTAssertTrue(command(.toggleZoom).isEnabled(store))
        XCTAssertEqual(command(.toggleZoom).title(store), "Zoom Pane")

        store.toggleZoom(pane.id, in: store.tabs[index].id)
        XCTAssertEqual(command(.toggleZoom).title(store), "Unzoom Pane")
    }

    /// The trailing end of a row is the value a command acts on where there is
    /// one, and the chord otherwise — so Change Session names the session you
    /// would be leaving rather than repeating ⌘K at you.
    func testTheSessionCommandsNameTheSessionTheyWouldActOn() {
        let store = emptyStore()
        list(store, [(1, "work", [1])])

        XCTAssertEqual(command(.changeSession).detail?(store), "work")
        XCTAssertEqual(command(.renameSession).detail?(store), "work")
        XCTAssertNil(command(.newTerminal).detail?(store))
    }

    // MARK: - What the field means

    /// The dropdown's rule, and only the dropdown's rule: trimmed,
    /// case-insensitive, substring, in the order the table is written. No
    /// ranking, because ranking is a second rule to keep and the dropdown has
    /// done without one.
    func testPaletteRowsFilterTheWayTheDropdownDoes() {
        let store = emptyStore()

        let everything = store.paletteCommands(matching: "")
        XCTAssertEqual(everything.count, CommandID.allCases.count - 1)
        // The table's order, written out rather than compared against
        // `Commands.paletteVisible`: the empty-query branch *returns* that
        // array, so holding one against the other asserts that a value equals
        // itself and passes with any ranking at all bolted on underneath.
        // These four are the top of the table as `Commands.all` writes it.
        XCTAssertEqual(
            Array(everything.prefix(4).map(\.id)),
            [.changeSession, .renameSession, .deleteSession, .switchHost],
            "the panel opened on something other than the top of the table")

        // The panel never offers to open the panel you are looking at, even
        // when what has been typed is its own name.
        XCTAssertFalse(everything.contains { $0.id == .commandPalette })
        XCTAssertTrue(store.paletteCommands(matching: "Command Palette").isEmpty)

        XCTAssertEqual(
            store.paletteCommands(matching: "  SPLIT ").map(\.id), [.splitRight, .splitDown],
            "the ends of what was typed were treated as part of it, or case was")
        XCTAssertEqual(
            store.paletteCommands(matching: "host").map(\.id),
            [.switchHost, .addRemoteHost, .forgetHost],
            "the matches came back in some order other than the table's")
        XCTAssertTrue(store.paletteCommands(matching: "zzz").isEmpty)
    }

    /// A choice prompt's options narrow on the same rule, and a command with no
    /// prompt — or a free-text one — has none to narrow.
    ///
    /// Three machines, because Switch Host leaves out the one the window is on
    /// and two would leave a list of one with nothing to narrow.
    func testChoicesNarrowOnTheSameRuleAsCommands() {
        let store = emptyStore([Self.local, Self.remote, Self.otherRemote])

        XCTAssertEqual(
            store.paletteChoices(for: .switchHost, matching: "").map(\.title),
            ["build-box", "web-01"])
        XCTAssertEqual(
            store.paletteChoices(for: .switchHost, matching: " BUILD ").map(\.title),
            ["build-box"])
        XCTAssertTrue(store.paletteChoices(for: .addRemoteHost, matching: "").isEmpty)
        XCTAssertTrue(store.paletteChoices(for: .newTerminal, matching: "").isEmpty)
    }

    /// Two machines can be called the same thing — `Local` is the local
    /// daemon's display name and is also a perfectly legal SSH destination —
    /// and a `PaletteChoice`'s id has to tell them apart anyway: `ForEach`
    /// keys on it, so a collision is two rows SwiftUI believes are one, and
    /// `scrollTo` keys on it, so an arrow onto the second scrolls to the
    /// first. `Commands.choiceID` is what stops it, and nothing pinned that.
    func testTwoMachinesWithOneNameStillHaveDistinctChoiceIds() {
        let namesake = ServerHost.ssh(destination: "Local")
        let store = emptyStore([Self.local, namesake, Self.remote])
        // Onto the third machine, so that the two namesakes are both offered:
        // the list leaves out the machine the window is on, and the window
        // starts on the local daemon.
        store.switchHost(Self.remote)

        let options = store.paletteChoices(for: .switchHost, matching: "")
        XCTAssertEqual(options.map(\.title), ["Local", "Local"], "the fixture stopped colliding")
        XCTAssertEqual(
            Set(options.map(\.id)).count, 2,
            "an SSH destination called Local took the local daemon's row id")
    }

    // MARK: - Running things

    /// Running anything dismisses the panel.
    ///
    /// Refresh Sessions on purpose — a command whose action touches neither
    /// overlay, so the only thing that can have closed the panel is
    /// `runCommand`'s own dismissal. Every other command reaches `palette ==
    /// nil` by some second route and would pass this with the dismissal
    /// deleted.
    ///
    /// The *ordering* — dismissing before the action rather than after — is not
    /// pinned here, and cannot be: the two `didSet`s make both orders converge
    /// on identical state for every command in the table, so no assertion this
    /// store can make tells them apart. It lives as the reasoning at
    /// `SessionStore.runCommand`, which is where Close Tab taking the window
    /// out from under a panel is argued. Saying so out loud is the house move —
    /// `focusGeneration` names the half of the focus story its counter does not
    /// cover, and `Commands.swift`'s header names the direction of drift its
    /// table cannot close.
    func testRunningACommandDismissesThePanel() {
        let store = emptyStore()
        store.palette = .commands

        store.runCommand(.refreshSessions)

        XCTAssertNil(store.palette, "the panel stayed up over whatever the command did")
    }

    /// And a command that raises the dropdown gets a dropdown: the exclusion
    /// between the two overlays must not eat the thing the command was for.
    func testChangeSessionHandsOverToTheDropdown() {
        let store = emptyStore()
        store.palette = .commands

        store.runCommand(.changeSession)

        XCTAssertTrue(store.sessionMenuOpen, "the dropdown it opened was closed again")
        XCTAssertNil(store.palette)
    }

    /// The one command the panel never lists is the one that owns it, and it
    /// is the exception to dismissing first: closing before the toggle ran
    /// would have ⇧⌘P find the panel already shut and open it again, so the
    /// chord that opens the palette could never close it.
    func testTheChordThatOpensThePaletteAlsoClosesIt() {
        let store = emptyStore()

        store.runCommand(.commandPalette)
        XCTAssertEqual(store.palette, .commands)

        store.runCommand(.commandPalette)
        XCTAssertNil(store.palette, "⇧⌘P shut the panel and the same keystroke reopened it")
    }

    /// A command that needs an argument asks for it in place. Nothing of what
    /// it does happens on the way to asking.
    func testACommandWithAPromptBecomesOneRatherThanRunning() {
        let store = emptyStore([Self.local, Self.remote])
        store.palette = .commands

        store.runCommand(.switchHost)

        XCTAssertEqual(store.palette, .argument(.switchHost))
        XCTAssertEqual(
            store.currentHost, Self.local, "it switched a machine on its way to asking which")
    }

    /// Dimmed rows are drawn because hiding them would make the panel lie about
    /// what the app can do. They are unreachable because a row whose Return
    /// does nothing is the silent no-op this codebase keeps killing — so the
    /// guard is in the store, where a click and a keystroke both pass it.
    func testADisabledCommandNeitherRunsNorPrompts() {
        let store = emptyStore()
        store.palette = .commands

        // Nothing in front to delete.
        XCTAssertFalse(command(.deleteSession).isEnabled(store))
        store.runCommand(.deleteSession)
        XCTAssertNil(store.pendingDestruction, "a dimmed row put a destructive dialog up")
        XCTAssertEqual(store.palette, .commands, "a dimmed row dismissed the panel")

        // One machine is not a choice: a prompt whose single option puts you
        // where you already are is a lie about what the app can do.
        XCTAssertFalse(command(.switchHost).isEnabled(store))
        store.runCommand(.switchHost)
        XCTAssertEqual(store.palette, .commands, "a dimmed row opened a prompt")
    }

    // MARK: - The host verbs

    /// Taking an option moves the window and takes the panel down — and the
    /// machine the window is already on is not one of the options.
    ///
    /// `switchHost` guards on `target != currentHost` and returns, so that row
    /// closed the panel and did nothing, which is the same defect the Forget
    /// Host list avoids by leaving out the local daemon. It is also what makes
    /// `chooseOption` safe to write as a close followed by an action.
    func testChoosingAHostSwitchesAndClosesAndTheMachineYouAreOnIsNotOffered() throws {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "here", [1])])
        list(store, host: Self.remote, [(1, "there", [1])])

        store.runCommand(.switchHost)
        let options = store.paletteChoices(for: .switchHost, matching: "")
        XCTAssertEqual(
            options.map(\.title), ["build-box"],
            "the machine the window was already on was offered as somewhere to go")
        XCTAssertTrue(
            options.allSatisfy { !$0.isCurrent },
            "a checkmark was drawn on a machine this list does not contain")

        store.chooseOption(try XCTUnwrap(options.last))

        XCTAssertEqual(store.currentHost, Self.remote)
        XCTAssertNil(store.palette, "the panel stayed up on the machine it had just left")

        // And it moves with the window: what was left out a moment ago is what
        // is offered now.
        XCTAssertEqual(
            store.paletteChoices(for: .switchHost, matching: "").map(\.title), ["Local"])
    }

    /// The local daemon is not something the user added, and `removeHost`
    /// refuses it — so offering it here would be a row whose Return does
    /// nothing, which is the thing the dimming rule exists to prevent.
    func testForgetHostOffersOnlyTheMachinesYouAdded() throws {
        let store = emptyStore([Self.local, Self.remote])

        XCTAssertEqual(
            store.paletteChoices(for: .forgetHost, matching: "").map(\.title), ["build-box"],
            "the local daemon was offered as something to forget")
        XCTAssertTrue(command(.forgetHost).isEnabled(store))

        store.runCommand(.forgetHost)
        let options = store.paletteChoices(for: .forgetHost, matching: "")
        store.chooseOption(try XCTUnwrap(options.first))

        XCTAssertEqual(store.hosts.map(\.host), [Self.local])
        XCTAssertNil(store.palette)

        // And with nothing left to forget it greys out rather than offering an
        // empty list to press Return on.
        XCTAssertFalse(command(.forgetHost).isEnabled(store))
        XCTAssertTrue(store.paletteChoices(for: .forgetHost, matching: "").isEmpty)
    }

    /// The trim and the refusal came off the sheet this replaced, where they
    /// were the Add button's `.disabled` and its commit's guard. Both are the
    /// store's now, so the field cannot validate one string and send another —
    /// which is exactly how the dropdown's rename once went wrong.
    ///
    /// The rule is asserted on its own, and that is the point rather than
    /// tidiness. This test used to drive the trim by committing a padded
    /// address against a store that held the unpadded one, which was safe
    /// *only while the trim worked*: broken, the padded string is a
    /// destination the store does not hold, `addHost` falls through to
    /// `connect: true`, and the suite spawns a real `ssh` — the regression
    /// this file's header says it guards against, reintroduced on the one path
    /// nobody watches. Every string handed to `commitAddHost` below resolves
    /// to a host the store already holds and has marked connected, whichever
    /// way the trim goes, so no branch of any regression dials anything.
    func testCommittingAnAddressIsTrimmedAndCommittingNothingIsRefused() {
        XCTAssertEqual(SessionStore.destination("  build-box  "), "build-box")
        XCTAssertNil(SessionStore.destination("   "))
        XCTAssertNil(SessionStore.destination(""))

        let store = emptyStore()
        // `build-box` is what a working trim commits; the other two are what a
        // broken one commits, and they are here so that it cannot dial.
        let held: [ServerHost] = [
            Self.remote, .ssh(destination: "  build-box  "), .ssh(destination: "   "),
        ]
        for host in held {
            store.addHost(host, connect: false)
            store.host(host)?.setStatusForTesting(.connected)
        }
        store.runCommand(.addRemoteHost)

        // Whitespace is not an address. The panel stays where it is with the
        // caret where it was, which is the whole of the feedback a field with
        // nothing in it can want — and a commit that got as far as `addHost`
        // would have closed it.
        store.commitAddHost("   ")
        XCTAssertEqual(
            store.palette, .argument(.addRemoteHost),
            "a field with nothing in it was committed as an address")

        store.commitAddHost("  build-box  ")
        XCTAssertEqual(
            store.hosts.map(\.host), [Self.local] + held,
            "a machine already in the list was added to it a second time")
        XCTAssertNil(store.palette)
    }

    /// The dropdown's last row, which used to raise a sheet. It arms the
    /// palette's prompt instead, and the dropdown goes — one gesture, one
    /// surface, and no `isPresented = false` at the call site to be a second
    /// door.
    func testTheDropdownsAddHostRowArmsThePalettePrompt() {
        let store = emptyStore()
        store.sessionMenuOpen = true

        store.beginAddRemoteHost()

        XCTAssertEqual(store.palette, .argument(.addRemoteHost))
        XCTAssertFalse(store.sessionMenuOpen, "the dropdown stayed up under the panel")
    }

    // MARK: - One overlay at a time

    /// Held by the two `didSet`s rather than by every caller remembering, for
    /// the reason `selectedTabID` is a `didSet`: SwiftUI writes both of these
    /// properties directly — the session button binds to `sessionMenuOpen` —
    /// so a method they were all supposed to call would be a funnel with
    /// bypasses.
    func testOpeningOneOverlayClosesTheOther() {
        let store = emptyStore()

        store.sessionMenuOpen = true
        store.palette = .commands
        XCTAssertFalse(store.sessionMenuOpen, "two panels were on screen at once")

        store.sessionMenuOpen = true
        XCTAssertNil(store.palette, "two panels were on screen at once")

        // Closing one leaves the other alone, which is what keeps the pair of
        // observers from being a loop: the second write finds nothing to
        // change.
        store.palette = nil
        XCTAssertTrue(store.sessionMenuOpen)
        store.sessionMenuOpen = false
        store.palette = .commands
        XCTAssertEqual(store.palette, .commands)
    }

    /// ⇧⌘P from either side, and ⌫ taking the chip back.
    func testThePanelTogglesAndAnArgumentPopsBackToTheList() {
        let store = emptyStore([Self.local, Self.remote])

        store.togglePalette()
        XCTAssertEqual(store.palette, .commands)
        store.togglePalette()
        XCTAssertNil(store.palette)

        // ⌫ on an empty argument field is one step back, not a dismissal:
        // deleting the chip leaves you in the panel you opened.
        store.runCommand(.switchHost)
        store.popPaletteArgument()
        XCTAssertEqual(store.palette, .commands)

        // And there is no step back to take from stage one, nor from a panel
        // that is not on screen at all — the monitor only claims ⌫ in stage
        // two, but the guard is here so that the rule survives the monitor.
        store.popPaletteArgument()
        XCTAssertEqual(store.palette, .commands, "⌫ in the search field closed the panel")

        store.closePalette()
        store.popPaletteArgument()
        XCTAssertNil(store.palette, "⌫ opened a panel that was not there")
    }

    // MARK: - The geometry a test can hold

    /// The list is as tall as its rows, up to sixteen of them.
    ///
    /// Written down rather than left to the `ScrollView`, which is greedy in
    /// its scroll axis: handed the window's height to fill it takes all of it,
    /// so a filter narrowed to two rows drew a panel sixteen rows tall with
    /// fourteen rows of nothing under it.
    func testTheListIsAsTallAsItsRowsUpToSixteen() {
        XCTAssertEqual(
            PaletteMetrics.listHeight(rows: 2), 2 * PaletteMetrics.rowHeight,
            "a two-row filter drew a full-height panel")
        // No assertion that sixteen rows are `listMaxHeight`: that constant
        // *is* sixteen rows and `listHeight` is a `min` against it, so the two
        // cannot come out different however the function is written. The
        // clamp's work is the twenty-two below.
        //
        // The unfiltered table is longer than sixteen, so the panel opens
        // clamped and scrolling — which is the state the reference measures,
        // scroll indicator and all.
        XCTAssertGreaterThan(Commands.paletteVisible.count, PaletteMetrics.maxRows)
        XCTAssertEqual(
            PaletteMetrics.listHeight(rows: Commands.paletteVisible.count),
            PaletteMetrics.listMaxHeight)
        // Nothing matched, so the panel is one row of "no matching commands".
        // Zero would collapse the list to a hairline and leave the notice
        // clipped out of a panel that looks broken.
        XCTAssertEqual(PaletteMetrics.listHeight(rows: 0), PaletteMetrics.rowHeight)
        // The panel's row is its own and taller than the dropdown's, which is
        // the correction the file header records: built out of `MenuMetrics`
        // throughout, the panel came out too wide for rows that were too
        // tight. Asserted rather than left implicit so that folding this back
        // into `MenuMetrics.rowHeight` — the obvious tidy-up — fails here
        // instead of silently undoing the measurement.
        XCTAssertGreaterThan(PaletteMetrics.rowHeight, MenuMetrics.rowHeight)
    }

    /// And never taller than the window it is centred in.
    ///
    /// Sixteen rows is a count, and it stopped being a safe one when the row
    /// grew: they are 400pt of list in a 441pt panel, which wants 501pt of
    /// content area once the inset it hangs at and the margin under it are
    /// counted — against a window this app lets you make 460pt tall. Without
    /// the clamp such a window got a palette running off the bottom edge with
    /// its last commands unreachable, since arrowing onto one scrolls it into
    /// a part of the list that is outside the window too.
    func testTheListNeverOutgrowsTheWindowItIsCentredIn() {
        // The two figures the paragraph above and `PaletteMetrics.maxRows`
        // both quote. Pinned because this panel's constants have moved four
        // times and the arithmetic in the comments around them did not move
        // once: whatever changes these, the sentences naming 400 and 441 have
        // to change in the same commit.
        XCTAssertEqual(PaletteMetrics.listMaxHeight, 400, "sixteen rows are no longer 400pt")
        XCTAssertEqual(
            PaletteMetrics.listMaxHeight + PaletteMetrics.listOverhead, 441,
            "the full-height panel is no longer 441pt")

        // Room for all sixteen: the count is what bites, exactly as before.
        XCTAssertEqual(
            PaletteMetrics.listHeight(rows: 16, in: 1200), PaletteMetrics.listMaxHeight,
            "a window with room to spare clamped a list that fitted in it")

        // Room for fewer. Whole rows, and the panel they make still fits under
        // the inset it hangs at with the same margin left beneath it.
        let short: CGFloat = 500
        let list = PaletteMetrics.listHeight(rows: 16, in: short)
        XCTAssertLessThan(list, PaletteMetrics.listMaxHeight)
        XCTAssertEqual(
            list.truncatingRemainder(dividingBy: PaletteMetrics.rowHeight), 0,
            "the list ended in a sliver of a row")
        XCTAssertLessThanOrEqual(
            list + PaletteMetrics.listOverhead + 2 * PaletteMetrics.topInset, short,
            "the panel hung off the bottom of the window")

        // Less room than one row, which is not a window anybody has, and still
        // not a list of nothing: the notice has to be somewhere.
        XCTAssertEqual(PaletteMetrics.listHeight(rows: 8, in: 100), PaletteMetrics.rowHeight)

        // Zero is a container SwiftUI has not laid out yet rather than a window
        // with no room in it. Clamping against it would open every palette one
        // row tall for the frame before the real height arrives.
        XCTAssertEqual(
            PaletteMetrics.listHeight(rows: 8, in: 0), PaletteMetrics.listHeight(rows: 8),
            "an unmeasured container clamped the list to one row")
    }

    // MARK: - The two key rules

    /// What AppKit puts in an arrow key's modifier mask whether or not anybody
    /// held anything down. The fixture is honest about it because the claim
    /// rule's whole trap is here — see `PaletteKeys.heldModifiers`.
    private static let bareArrow: NSEvent.ModifierFlags = [.function, .numericPad]

    /// The arrows are the panel's in both stages; ⌫ is the field's everywhere
    /// but the one position where the field has nothing to correct.
    func testBackspaceClaimsOnlyAnEmptyArgumentField() {
        func claim(
            _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], argument: Bool,
            empty: Bool
        ) -> PaletteKeys.Claim {
            PaletteKeys.claim(
                keyCode: keyCode, modifiers: modifiers, stageIsArgument: argument,
                queryIsEmpty: empty)
        }

        XCTAssertEqual(claim(PaletteKeys.delete, argument: true, empty: true), .popArgument)
        XCTAssertEqual(
            claim(PaletteKeys.delete, argument: true, empty: false), .pass,
            "⌫ took the chip instead of the character it was aimed at")
        XCTAssertEqual(
            claim(PaletteKeys.delete, argument: false, empty: true), .pass,
            "⌫ in the search field had nothing to take back and took something")

        XCTAssertEqual(
            claim(PaletteKeys.upArrow, Self.bareArrow, argument: false, empty: false), .up)
        XCTAssertEqual(
            claim(PaletteKeys.downArrow, Self.bareArrow, argument: true, empty: true), .down)

        // `kVK_ANSI_N`. Everything the field can use goes to the field.
        XCTAssertEqual(claim(45, argument: true, empty: true), .pass)
        // Escape is `onEscape`'s, and two owners of one key is one of them
        // winning by accident.
        XCTAssertEqual(claim(53, argument: true, empty: true), .pass)
        // As is Return, which reaches the field as `.onSubmit`.
        XCTAssertEqual(claim(36, argument: false, empty: false), .pass)
    }

    /// A modified key is a chord, and a chord is a command's name — so the
    /// panel does not take it. Four of the app's chords are arrows (⌥⌘←→↑↓,
    /// Focus Pane), and a chord arrives with the same keycode as the bare key
    /// under it; claiming on the keycode alone swallowed ⌥⌘↑ and ⌥⌘↓ to move
    /// the highlight while ⌥⌘← and ⌥⌘→ went past and moved pane focus.
    func testModifiedChordsBelongToTheMenuBarAndTheField() {
        func claim(
            _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, argument: Bool = false,
            empty: Bool = false
        ) -> PaletteKeys.Claim {
            PaletteKeys.claim(
                keyCode: keyCode, modifiers: modifiers, stageIsArgument: argument,
                queryIsEmpty: empty)
        }

        // Focus Pane Above. The menu bar's, and on its way there it takes the
        // panel down through `runCommand` — symmetric with ⌥⌘←, which was
        // already doing exactly that.
        XCTAssertEqual(
            claim(PaletteKeys.upArrow, Self.bareArrow.union([.option, .command])), .pass,
            "⌥⌘↑ moved the highlight while ⌥⌘← moved pane focus")
        XCTAssertEqual(claim(PaletteKeys.downArrow, Self.bareArrow.union(.command)), .pass)
        // ⇧-arrow is the field selecting text.
        XCTAssertEqual(claim(PaletteKeys.upArrow, Self.bareArrow.union(.shift)), .pass)
        // ⌥⌫ is a word delete, and stays the field's even with nothing to
        // delete: somebody who has learnt it has not learnt "unless empty".
        XCTAssertEqual(
            claim(PaletteKeys.delete, .option, argument: true, empty: true), .pass,
            "⌥⌫ took the chip instead of reaching the field")

        // And the trap the guard is written around: an arrow always carries
        // `.function` and `.numericPad`, so an emptiness test on the raw mask —
        // or on `deviceIndependentFlagsMask` — passes every arrow through and
        // leaves the panel with no navigation at all.
        XCTAssertEqual(
            claim(PaletteKeys.upArrow, Self.bareArrow), .up,
            "the modifier guard mistook an arrow's own flags for a chord")
        XCTAssertFalse(Self.bareArrow.isEmpty, "the fixture stopped exercising the trap")
    }

    /// Where an arrow lands among rows that are not all selectable, and where
    /// the highlight goes when a filter has just changed under it.
    func testArrowSelectionSkipsDisabledRowsAndClampsAtTheEnds() {
        let rows = [true, false, false, true, false]

        XCTAssertEqual(
            PaletteKeys.step(from: 0, by: 1, enabled: rows), 3,
            "the highlight stopped on a row whose Return does nothing")
        XCTAssertEqual(
            PaletteKeys.step(from: 3, by: 1, enabled: rows), 3,
            "it walked off the end of the list")
        XCTAssertEqual(PaletteKeys.step(from: 3, by: -1, enabled: rows), 0)
        XCTAssertEqual(
            PaletteKeys.step(from: 0, by: -1, enabled: rows), 0,
            "it wrapped rather than clamping, and lost the person's place")

        // The first selectable row is the same walk, from before the list —
        // one rule rather than a second search that could disagree with this
        // one about which rows count.
        XCTAssertEqual(PaletteKeys.step(from: -1, by: 1, enabled: [false, false, true]), 2)
        XCTAssertEqual(
            PaletteKeys.step(from: -1, by: 1, enabled: [false, false]), -1,
            "a list with nothing runnable in it still highlighted something")
        XCTAssertEqual(PaletteKeys.step(from: -1, by: 1, enabled: []), -1)
    }

    /// And where it goes when the row *under* it dims — nothing typed, nothing
    /// moved, the app changed. Delete Session… greys out when its machine
    /// drops; Close Tab greys out when the last tab is closed by the
    /// titlebar's ✕, which stays live under the panel. The highlight used to
    /// stay put and Return then did nothing at all, which is the silent no-op
    /// the dimming rule exists to prevent, arriving from the one direction
    /// `resetSelection` does not watch.
    func testTheHighlightLeavesARowThatDimsUnderIt() {
        // Still runnable: nothing moves. A re-step that always stepped would
        // walk the highlight down the list on every reconcile.
        XCTAssertEqual(PaletteKeys.restep(from: 1, enabled: [true, true, true]), 1)

        // Forward first, the way an arrow was going.
        XCTAssertEqual(PaletteKeys.restep(from: 1, enabled: [true, false, true]), 2)

        // Then back, for a row that dimmed with nothing runnable after it —
        // Show Previous Tab is the last row in the table and greys out the
        // moment a window is down to one tab.
        XCTAssertEqual(
            PaletteKeys.restep(from: 2, enabled: [true, false, false]), 0,
            "the highlight stayed on a dimmed row because the list ended after it")

        // Then nothing, which is honest: a list with nothing runnable in it
        // should not be pointing at a row.
        XCTAssertEqual(PaletteKeys.restep(from: 1, enabled: [false, false]), -1)
        XCTAssertEqual(PaletteKeys.restep(from: 0, enabled: []), -1)

        // An index off the end is the list having *shrunk* rather than a row
        // having dimmed, and starts again from the top. `step` cannot walk in
        // from outside — it stops the moment it is off the end — so this is
        // the case that needs saying separately.
        XCTAssertEqual(
            PaletteKeys.restep(from: 9, enabled: [false, true]), 1,
            "a list that shrank under the highlight left it pointing past the end")
    }

    /// A hover only counts once the pointer has moved.
    ///
    /// Hover callbacks fire whenever the view under the pointer changes, and
    /// the pointer does not have to be what changed it. The panel is centred
    /// and hangs 30pt down, so opening it lands a row under a mouse that is
    /// very often already resting there — ⇧⌘P then Return ran whatever the
    /// pointer happened to be over rather than the first row. And an arrow
    /// past the visible fold scrolls the list, which puts a new row under that
    /// same still pointer, whose hover snapped the highlight back: with the
    /// mouse anywhere over the panel, the end of the table could not be
    /// reached by arrow at all.
    func testAHoverCountsOnlyOnceThePointerHasMoved() {
        let resting = CGPoint(x: 400, y: 300)

        XCTAssertFalse(
            PaletteKeys.hoverMoved(from: nil, to: resting),
            "the panel opened under the pointer and handed it the highlight")
        XCTAssertFalse(
            PaletteKeys.hoverMoved(from: resting, to: resting),
            "a row scrolled under a still pointer and took the highlight off the arrows")
        XCTAssertTrue(
            PaletteKeys.hoverMoved(from: resting, to: CGPoint(x: resting.x, y: resting.y + 1)),
            "the mouse moved and the highlight did not follow it")
    }

    // MARK: - What a launch flag can open

    /// The two rules `init` holds by hand, because they are about a property's
    /// *initial* value and a `didSet` does not run for one.
    ///
    /// Both are reachable from a screenshot script and neither was reachable
    /// from a test until the launch state became an argument: an assignment
    /// from a test runs the observers, which is precisely what these two
    /// repairs exist to stand in for. Passing them in is the whole seam.
    func testBothLaunchFlagsAtOnceStillLeaveOneOverlay() {
        let store = SessionStore(
            hosts: [Self.local], defaults: InMemoryDefaults(),
            launcher: RecordingLauncher(.succeedSilently),
            sessionMenuOpen: true, palette: .commands)

        XCTAssertEqual(store.palette, .commands)
        XCTAssertFalse(
            store.sessionMenuOpen,
            "a screenshot script asking for both got two overlays on screen at once")
    }

    /// And a launch flag cannot arm a prompt the panel itself would refuse to
    /// open. `launchStage` checks that the command *has* a prompt, which is a
    /// fact about the table; whether it is enabled is a fact about the store,
    /// and there is no store yet while its own properties are being computed —
    /// so `init` makes the check `runCommand` makes for every other door.
    func testALaunchFlagCannotOpenAPromptTheCommandIsTooDisabledToOffer() {
        func store(_ hosts: [ServerHost]) -> SessionStore {
            SessionStore(
                hosts: hosts, defaults: InMemoryDefaults(),
                launcher: RecordingLauncher(.succeedSilently), palette: .argument(.switchHost))
        }

        // One machine is nowhere to switch to, and the panel draws that row
        // dimmed. Opening on the list instead is the same fallback a value
        // naming no prompt at all gets.
        XCTAssertEqual(
            store([Self.local]).palette, .commands,
            "a launch flag armed a prompt off a row the panel refuses to run")
        // Two, and the command is enabled, so the flag gets what it asked for.
        XCTAssertEqual(store([Self.local, Self.remote]).palette, .argument(.switchHost))
    }
}
