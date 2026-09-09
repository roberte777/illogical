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
//  The **state machine** is a pair of `didSet`s and four methods on the store.
//  It decides which overlay is up, whether a command runs or asks for an
//  argument first, and what a filter means — every one of which used to be the
//  kind of thing a view was trusted to remember.
//
//  The **key rules** are two pure functions. The monitor around them cannot be
//  driven from a unit test, exactly as `EscapeKey`'s and `TabCycleKey`'s
//  cannot, but the decisions can: every key wrongly claimed is a keystroke the
//  search field stops receiving, and an arrow that lands on a dimmed row is a
//  Return that does nothing.
//
//  Driven without a socket throughout, and deliberately without dialling one
//  either. `CurrentHostTests` records the regression this is guarding against
//  in as many words — two suites once spawned a real `ssh build-box` per run —
//  so the one test that reaches `addHost` arranges for the destination to be a
//  machine the store already holds and marks it connected first, which is the
//  branch that returns without connecting anything.

import Foundation
import IllogicalProtocol
import XCTest

@MainActor
final class CommandPaletteTests: XCTestCase {
    private static let local = ServerHost.local(socketPath: "/tmp/illogical-palette.sock")
    private static let remote = ServerHost.ssh(destination: "build-box")

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
        XCTAssertEqual(everything.map(\.id), Commands.paletteVisible.map(\.id))
        XCTAssertEqual(everything.count, CommandID.allCases.count - 1)

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
    func testChoicesNarrowOnTheSameRuleAsCommands() {
        let store = emptyStore([Self.local, Self.remote])

        XCTAssertEqual(
            store.paletteChoices(for: .switchHost, matching: "").map(\.title),
            ["Local", "build-box"])
        XCTAssertEqual(
            store.paletteChoices(for: .switchHost, matching: " BUILD ").map(\.title),
            ["build-box"])
        XCTAssertTrue(store.paletteChoices(for: .addRemoteHost, matching: "").isEmpty)
        XCTAssertTrue(store.paletteChoices(for: .newTerminal, matching: "").isEmpty)
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

    func testChoosingAHostSwitchesAndCloses() throws {
        let store = emptyStore([Self.local, Self.remote])
        list(store, [(1, "here", [1])])
        list(store, host: Self.remote, [(1, "there", [1])])

        store.runCommand(.switchHost)
        let options = store.paletteChoices(for: .switchHost, matching: "")
        XCTAssertEqual(options.filter(\.isCurrent).map(\.title), ["Local"])

        store.chooseOption(try XCTUnwrap(options.last))

        XCTAssertEqual(store.currentHost, Self.remote)
        XCTAssertNil(store.palette, "the panel stayed up on the machine it had just left")
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
    /// `build-box` is already in the store and already marked connected, so
    /// `addHost` takes its "already here, and it is working" branch and dials
    /// nothing. A destination that arrived with its spaces still on it would
    /// be a *different* host, which is what the count catches.
    func testCommittingAnAddressIsTrimmedAndCommittingNothingIsRefused() {
        let store = emptyStore()
        store.addHost(Self.remote, connect: false)
        store.host(Self.remote)?.setStatusForTesting(.connected)
        store.runCommand(.addRemoteHost)

        // Whitespace is not an address. The panel stays where it is with the
        // caret where it was, which is the whole of the feedback a field with
        // nothing in it can want.
        store.commitAddHost("   ")
        XCTAssertEqual(store.palette, .argument(.addRemoteHost))
        XCTAssertEqual(store.hosts.count, 2)

        store.commitAddHost("  build-box  ")
        XCTAssertEqual(
            store.hosts.map(\.host), [Self.local, Self.remote],
            "a destination was added with its whitespace still on it")
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

    // MARK: - The one piece of geometry a test can hold

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
        XCTAssertEqual(PaletteMetrics.listHeight(rows: 16), PaletteMetrics.listMaxHeight)
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
}
