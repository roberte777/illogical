//  Commands.swift
//  Every verb the app has, written down once.
//
//  Two surfaces now offer the same things to do — the menu bar and the command
//  palette — and as two hand-written lists they would drift. `listValuedKeys`
//  in IllogicalConfig already argued the general case in as many words: routed
//  through one table there is nothing to keep in sync. A title changed here is
//  changed in both, and the palette's trailing shortcut text is *derived* from
//  the very `KeyboardShortcut` the menu item applies — so the two cannot
//  disagree about what ⇧⌘N is, which is the failure a second list makes
//  invisible until somebody notices the palette advertising a chord that was
//  moved a release ago.
//
//  What is deliberately **not** in the table is placement. SwiftUI wants
//  `CommandGroup` placement, dividers and submenu structure written out
//  statically, and more to the point where an item sits in the menu bar is a
//  fact about the menu bar rather than about the verb. So `IllogicalApp.swift`
//  still writes its groups out by hand, with the comments that explain their
//  order, and reaches in here for the four things that belong to the verb:
//  title, chord, whether it is enabled, and what it does.
//
//  One direction of drift this cannot close: a command in the table that no
//  menu group ever places, which would be a palette row with no menu item
//  behind it. That is not testable from here. `IllogicalRendererTests` is an
//  unhosted `bundle.unit-test`, so there is no `NSApp.mainMenu` to walk, and
//  `IllogicalApp.swift` is not among its sources. It is a review item, said
//  out loud here the way `focusGeneration` says which half of the focus story
//  its counter actually covers.

import IllogicalProtocol
import SwiftUI

/// Everything the menu bar or the palette can ask for. The raw values are
/// never persisted or sent anywhere — `String` is here so a missing table
/// entry traps with a name in the message rather than with a number.
enum CommandID: String, CaseIterable {
    case commandPalette
    case changeSession
    case renameSession
    case deleteSession
    case switchHost
    case addRemoteHost
    case forgetHost
    case newTerminal
    case newSession
    case splitRight
    case splitDown
    case toggleZoom
    case closeTab
    case find
    case findNext
    case findPrevious
    case refreshSessions
    case focusPaneLeft
    case focusPaneRight
    case focusPaneAbove
    case focusPaneBelow
    case showNextTab
    case showPreviousTab
}

/// One verb: what it is called, what it costs to reach, whether it can be
/// reached at all, and what happens when it is.
///
/// Every field but `id` and `icon` is a function of the store rather than a
/// value, because half of them genuinely move: Zoom Pane becomes Unzoom Pane,
/// Change Session names the session you are in, and Delete Session… greys out
/// while its machine is being reconnected to. A stored string would be a
/// snapshot of the app taken at launch.
struct Command {
    let id: CommandID
    let title: @MainActor (SessionStore) -> String
    /// An SF Symbol drawn *inline* before the title in the palette, or nil.
    /// See `CommandPalette` for why this column is not reserved.
    let icon: String?
    /// The one definition of this command's chord. The menu item applies it;
    /// the palette formats it with `ShortcutDisplay`.
    let shortcut: KeyboardShortcut?
    /// The current value this command acts on — the session you are in, the
    /// machine you are on. Drawn where the shortcut would go, and winning over
    /// it when a command has both, because "which session am I about to
    /// rename" is the more useful of the two answers at the moment you are
    /// reading the row.
    let detail: (@MainActor (SessionStore) -> String?)?
    let isEnabled: @MainActor (SessionStore) -> Bool
    let action: Action

    /// What Return does: the whole thing, or the first half of it.
    enum Action {
        case run(@MainActor (SessionStore) -> Void)
        /// Needs an argument, so it narrows the palette to ask for one rather
        /// than opening anything of its own.
        case prompt(Prompt)
    }

    /// Stage two: the command collapsed into a chip, and a field that has
    /// stopped meaning "search commands" and started meaning "give me this
    /// command's argument".
    struct Prompt {
        /// The chip's text — a short form, because the chip sits inside a
        /// field that still has to have room to type in.
        let chip: String
        let placeholder: String
        /// The one line under the hairline. Free text only: a choice list puts
        /// the choices there instead, and they say more than a sentence could.
        let hint: String?
        let kind: Kind

        enum Kind {
            case text(commit: @MainActor (SessionStore, String) -> Void)
            case choice(options: @MainActor (SessionStore) -> [PaletteChoice])
        }
    }

    init(
        _ id: CommandID,
        title: @escaping @MainActor (SessionStore) -> String,
        icon: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        detail: (@MainActor (SessionStore) -> String?)? = nil,
        isEnabled: @escaping @MainActor (SessionStore) -> Bool = { _ in true },
        action: Action
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.detail = detail
        self.isEnabled = isEnabled
        self.action = action
    }

    /// The common case, where the title is a fixed string. Sugar over the
    /// initializer above, so that the one command whose title really does move
    /// — Zoom Pane — is the only line in the table that looks unusual.
    init(
        _ id: CommandID,
        title: String,
        icon: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        detail: (@MainActor (SessionStore) -> String?)? = nil,
        isEnabled: @escaping @MainActor (SessionStore) -> Bool = { _ in true },
        action: Action
    ) {
        self.init(
            id, title: { _ in title }, icon: icon, shortcut: shortcut, detail: detail,
            isEnabled: isEnabled, action: action)
    }
}

/// One option of a `choice` prompt: a machine to go to, a machine to forget.
///
/// Carries its own action rather than an index into some list the caller is
/// expected to re-derive. The list is rebuilt on every keystroke as the filter
/// narrows it, so an index would name a different host between the moment a row
/// was drawn and the moment Return reached it.
struct PaletteChoice: Identifiable {
    /// Unique among its siblings, which a display name is not: an SSH
    /// destination really can be called `Local`. `ForEach` and `scrollTo` both
    /// key on this.
    let id: String
    let title: String
    /// Drawn as a checkmark *after* the title, which is the whole of why the
    /// choice list reserves no icon column: a trailing glyph cannot move
    /// anything, so a choice row begins exactly where a command row does. The
    /// leading column that would have held it was built first and rejected —
    /// `PaletteRow.trailingIcon` carries that argument, and the file header of
    /// `CommandPalette` carries the measurement behind it.
    ///
    /// Switch Host sets it on the machine the window is on, which is the same
    /// row `isEnabled` is false for: "you are here" and "there is nowhere to
    /// go from here" are one fact said twice, once to the eye and once to
    /// Return. Forget Host has no current machine to mark.
    let isCurrent: Bool
    /// Whether Return can take this row, and deliberately `Command.isEnabled`'s
    /// word, because it is that mechanism rather than a second one: the palette
    /// dims the row (`PaletteRow.isEnabled`), the arrows step over it
    /// (`PaletteKeys.step`), a click on it does nothing, `CommandChoiceMenu`
    /// greys it in the menu bar, and `SessionStore.chooseOption` refuses it
    /// exactly as `runCommand` refuses a dimmed command.
    ///
    /// A `Bool` where a command's is a function of the store, and that is not
    /// an inconsistency: a choice list is *already* a function of the store,
    /// rebuilt from it on every keystroke, so the answer is known by the time
    /// there is a row to answer for.
    ///
    /// One row carries `false` today: Switch Host's machine you are already on,
    /// which `switchHost` returns for. Leaving that row out instead was tried
    /// and is what this replaced — it kills the same dead Return and takes the
    /// checkmark with it, because with no row to be on `isCurrent` can never be
    /// true and the menu bar's `Toggle` becomes the toggle that never toggles
    /// on. Forget Host's local daemon is a different rule and stays a filter:
    /// see there.
    let isEnabled: Bool
    let choose: @MainActor (SessionStore) -> Void
}

@MainActor
enum Commands {
    /// The table. Its order is the palette's order, so this list is also the
    /// answer to "what does ⇧⌘P show, and in what order".
    ///
    /// Grouped the way the palette reads top to bottom: the session you are
    /// in, the machine you are on, then making things, then the window. Not
    /// the menu bar's order — the menu bar is grouped by *menu*, which is a
    /// fact about where macOS puts things rather than about what you reach for
    /// first.
    static let all: [Command] = [
        // The palette itself. In the table because the menu bar item wants a
        // title and a chord from the same place everything else does; kept out
        // of `paletteVisible` because a row that opens the panel you are
        // already looking at is a row that does nothing.
        Command(
            .commandPalette, title: "Command Palette",
            shortcut: KeyboardShortcut("p", modifiers: [.command, .shift]),
            action: .run { $0.togglePalette() }),

        // Deliberately *not* a prompt. The app already has a polished filtered
        // session switcher with host headers, create-offers and inline rename;
        // a stage-two twin of it would be a worse copy that rots. So the
        // palette's row for this says which session you are in and hands over
        // to the dropdown, which is the same hand-off File ▸ Rename Session…
        // already performs.
        Command(
            .changeSession, title: "Change Session",
            shortcut: KeyboardShortcut("k", modifiers: .command),
            detail: { $0.selectedSessionSummary?.name },
            action: .run { $0.toggleSessionMenu() }),
        Command(
            .renameSession, title: "Rename Session…",
            detail: { $0.selectedSessionSummary?.name },
            isEnabled: { $0.selectedSession != nil },
            action: .run { store in
                guard let ref = store.selectedSession else { return }
                store.requestRenameSession(ref)
            }),
        // Greyed rather than hidden while the machine is being reconnected to,
        // for the reason the row's own context menu is: the session is still
        // listed, because the machine is still running it, but nothing can be
        // sent — and a dialog saying "this cannot be undone" for something
        // that cannot happen is worse than no menu item.
        Command(
            .deleteSession, title: "Delete Session…",
            isEnabled: { store in
                store.selectedSession.map { store.canDeleteSession($0) } ?? false
            },
            action: .run { store in
                guard let ref = store.selectedSession else { return }
                store.requestDeleteSession(ref)
            }),

        // Enabled only with somewhere to go. One machine is a list holding
        // nothing but the row for the machine you are on, which is the one row
        // in it Return cannot take — and a prompt with nothing to press Return
        // on is a lie about what the app can do.
        Command(
            .switchHost, title: "Switch Host", icon: "arrow.left.arrow.right",
            detail: { $0.current?.displayName },
            isEnabled: { $0.hosts.count > 1 },
            action: .prompt(
                Command.Prompt(
                    chip: "Switch Host", placeholder: "Search hosts...", hint: nil,
                    // Every machine, the one the window is on included. In the
                    // menu bar the checked `Toggle` is the only thing that says
                    // which machine that is, which is what excluding this row
                    // cost and why it is back. In the palette it is a second
                    // statement of it — the stage-one row already carries the
                    // machine's name as its `detail` — but the two surfaces
                    // read one table, so the row is drawn for both.
                    //
                    // And drawn *dimmed*. `switchHost` guards on `target !=
                    // currentHost` and returns — being somewhere is not a move
                    // — so a live row there is a Return that does nothing,
                    // which is the defect Forget Host names one entry below
                    // about the local daemon. Leaving it out answers that and
                    // costs the checkmark with it; `isEnabled: false` is the
                    // same refusal with the row still on screen, through the
                    // mechanism the command list has dimmed rows with all
                    // along. See `PaletteChoice.isEnabled`.
                    kind: .choice { store in
                        store.hosts.map { connection in
                            let isCurrent = connection.host == store.currentHost
                            return PaletteChoice(
                                id: Commands.choiceID(connection.host),
                                title: connection.displayName,
                                isCurrent: isCurrent,
                                isEnabled: !isCurrent,
                                choose: { $0.switchHost(connection.host) })
                        }
                    }))),
        // The wording is the sheet's, which this replaced: there is nothing to
        // ask for but a destination, because `ssh` reads the user's own config
        // and a `Host` alias out of it is a perfectly good answer.
        Command(
            .addRemoteHost, title: "Add Remote Host…", icon: "globe",
            action: .prompt(
                Command.Prompt(
                    chip: "Add Host", placeholder: "user@host",
                    hint: "user@host, or a Host from ~/.ssh/config",
                    kind: .text { store, typed in store.commitAddHost(typed) }))),
        // `network.slash` rather than the `globe.slash` this wants: SF Symbols
        // has no such glyph, and the negated network symbol is the closest
        // thing in the family the rest of the app's connectivity icons come
        // from.
        Command(
            .forgetHost, title: "Forget Host", icon: "network.slash",
            isEnabled: { $0.hosts.contains { $0.host.isRemote } },
            action: .prompt(
                Command.Prompt(
                    chip: "Forget Host", placeholder: "Search hosts...", hint: nil,
                    // Remote only, and a filter rather than the dimmed row
                    // Switch Host draws above. The two rules look alike and are
                    // not the same one: the local daemon is not something the
                    // user added, forgetting it would leave nowhere to make a
                    // terminal, and `removeHost` refuses it *always* — where
                    // "you are already on this machine" is a state that changes
                    // the moment you go somewhere else, and is worth a row to
                    // say so. There is nothing for a Forget Host row to say
                    // about the local daemon, so it has none.
                    kind: .choice { store in
                        store.hosts.filter { $0.host.isRemote }.map { connection in
                            PaletteChoice(
                                id: Commands.choiceID(connection.host),
                                title: connection.displayName,
                                isCurrent: false,
                                isEnabled: true,
                                choose: { $0.removeHost(connection.host) })
                        }
                    }))),

        Command(
            .newTerminal, title: "New Terminal",
            shortcut: KeyboardShortcut("t", modifiers: .command),
            action: .run { $0.createTerminal() }),
        Command(
            .newSession, title: "New Session",
            shortcut: KeyboardShortcut("n", modifiers: [.command, .shift]),
            action: .run { $0.createSession() }),
        // Split and Focus Pane carry predicates the menu items did not. Both
        // were silently no-ops with no tab in front — `split` and `moveFocus`
        // guard on `selectedTab` and return — so the menu has been offering
        // four focus items and two splits on the empty screen, all of them
        // doing nothing and none of them saying why.
        Command(
            .splitRight, title: "Split Right",
            shortcut: KeyboardShortcut("d", modifiers: .command),
            isEnabled: { $0.selectedTab != nil },
            action: .run { $0.split(.columns) }),
        Command(
            .splitDown, title: "Split Down",
            shortcut: KeyboardShortcut("d", modifiers: [.command, .shift]),
            isEnabled: { $0.selectedTab != nil },
            action: .run { $0.split(.rows) }),
        Command(
            .toggleZoom, title: { $0.selectedTab?.zoomed == nil ? "Zoom Pane" : "Unzoom Pane" },
            shortcut: KeyboardShortcut(.return, modifiers: [.command, .shift]),
            isEnabled: { $0.selectedTab?.isSplit == true },
            action: .run { $0.toggleZoomOnFocusedPane() }),
        Command(
            .closeTab, title: "Close Tab",
            shortcut: KeyboardShortcut("w", modifiers: [.command, .shift]),
            isEnabled: { $0.selectedTabID != nil },
            action: .run { store in
                guard let id = store.selectedTabID else { return }
                WindowClose.tab(id, in: store)
            }),

        Command(
            .find, title: "Find…",
            shortcut: KeyboardShortcut("f", modifiers: .command),
            isEnabled: { $0.selectedController != nil },
            action: .run { $0.beginFind() }),
        Command(
            .findNext, title: "Find Next",
            shortcut: KeyboardShortcut("g", modifiers: .command),
            isEnabled: { $0.canFindAgain },
            action: .run { $0.findNext() }),
        Command(
            .findPrevious, title: "Find Previous",
            shortcut: KeyboardShortcut("g", modifiers: [.command, .shift]),
            isEnabled: { $0.canFindAgain },
            action: .run { $0.findPrevious() }),
        Command(
            .refreshSessions, title: "Refresh Sessions",
            shortcut: KeyboardShortcut("r", modifiers: .command),
            action: .run { $0.refresh() }),

        Command(
            .focusPaneLeft, title: "Focus Pane Left",
            shortcut: KeyboardShortcut(.leftArrow, modifiers: [.command, .option]),
            isEnabled: { $0.selectedTab?.isSplit == true },
            action: .run { $0.moveFocus(.left) }),
        Command(
            .focusPaneRight, title: "Focus Pane Right",
            shortcut: KeyboardShortcut(.rightArrow, modifiers: [.command, .option]),
            isEnabled: { $0.selectedTab?.isSplit == true },
            action: .run { $0.moveFocus(.right) }),
        Command(
            .focusPaneAbove, title: "Focus Pane Above",
            shortcut: KeyboardShortcut(.upArrow, modifiers: [.command, .option]),
            isEnabled: { $0.selectedTab?.isSplit == true },
            action: .run { $0.moveFocus(.up) }),
        Command(
            .focusPaneBelow, title: "Focus Pane Below",
            shortcut: KeyboardShortcut(.downArrow, modifiers: [.command, .option]),
            isEnabled: { $0.selectedTab?.isSplit == true },
            action: .run { $0.moveFocus(.down) }),

        Command(
            .showNextTab, title: "Show Next Tab",
            shortcut: KeyboardShortcut("]", modifiers: [.command, .shift]),
            isEnabled: { $0.visibleTabs.count > 1 },
            action: .run { $0.selectNextTab() }),
        Command(
            .showPreviousTab, title: "Show Previous Tab",
            shortcut: KeyboardShortcut("[", modifiers: [.command, .shift]),
            isEnabled: { $0.visibleTabs.count > 1 },
            action: .run { $0.selectPreviousTab() }),
    ]

    /// What the palette lists: everything but the command that opens it.
    static var paletteVisible: [Command] { all.filter { $0.id != .commandPalette } }

    /// The table entry for an id.
    ///
    /// Traps rather than returning an optional. Every caller has a `CommandID`
    /// that came from this file, so a miss is a table with a hole in it and
    /// not a runtime condition — and the alternative, handing back some
    /// do-nothing placeholder, is precisely the silent no-op this codebase
    /// keeps killing. `CommandPaletteTests` pins the table against
    /// `CommandID.allCases`, so a hole cannot reach a build.
    static func command(_ id: CommandID) -> Command {
        guard let match = byID[id] else {
            preconditionFailure("no Commands.all entry for \(id.rawValue)")
        }
        return match
    }

    /// `uniquingKeysWith` is deliberately absent: two entries for one id is the
    /// other half of the same hole, and trapping at first use beats silently
    /// keeping whichever one happened to be last.
    private static let byID: [CommandID: Command] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The prompt behind a command, or nil for one that just runs.
    static func prompt(_ id: CommandID) -> Command.Prompt? {
        guard case .prompt(let prompt) = command(id).action else { return nil }
        return prompt
    }

    /// The options a choice prompt is currently offering. Empty for a command
    /// that has no prompt or whose prompt is free text — the menu bar draws
    /// these as a submenu, and an empty submenu is the honest rendering of a
    /// machine list with nothing in it.
    static func choices(_ id: CommandID, in store: SessionStore) -> [PaletteChoice] {
        guard let prompt = prompt(id), case .choice(let options) = prompt.kind else { return [] }
        return options(store)
    }

    /// A tooltip for a control that does exactly one command:
    /// `Change Session (⌘K)`, or the bare title where there is no chord to
    /// advertise.
    ///
    /// Here rather than written out beside each button, because those strings
    /// are precisely the copies this table exists to delete — and the one over
    /// the session button has drifted twice already. Its own comment records
    /// the second time: it said `⌘⇧K`, in the wrong modifier order *and* bound
    /// to nothing at all, and stayed that way until the View menu grew a
    /// Change Session item and somebody compared the two. A chord that moves in
    /// the table now moves in the tooltip, because the tooltip is no longer a
    /// second place it is written down.
    ///
    /// The second form below is for the controls whose noun is deliberately
    /// *not* the menu item's: a pane header says "Zoom" where the View menu
    /// says "Zoom Pane", because the header is already sitting on the pane it
    /// would zoom. Those keep their own wording and still take their chord
    /// from here, which is the half that goes stale.
    static func help(_ id: CommandID, _ store: SessionStore) -> String {
        help(id, titled: command(id).title(store))
    }

    /// The same tooltip for a control that says it in its own words — "Zoom"
    /// rather than "Zoom Pane", "Next Match" rather than "Find Next".
    ///
    /// No store parameter, because `Command.shortcut` is a stored value rather
    /// than a function of one: the only part of the table this reads is the
    /// part that cannot move underneath it. That also keeps `.toggleZoom`'s
    /// dynamic title out of the picture entirely, which is the point — the
    /// caller passing "Unzoom" has decided on a different word *and* a
    /// different state to read it from (the header knows which pane it is on;
    /// the menu item only knows which tab is in front).
    static func help(_ id: CommandID, titled title: String) -> String {
        guard let shortcut = command(id).shortcut else { return title }
        return "\(title) (\(ShortcutDisplay.string(shortcut)))"
    }

    private static func choiceID(_ host: ServerHost) -> String {
        switch host {
        case .local(let socketPath): "local:\(socketPath)"
        case .ssh(let destination, _): "ssh:\(destination)"
        }
    }
}

/// A chord as a person reads it: `⇧⌘N`, `⌥⌘←`, `⇧⌘↩`.
///
/// Derived from the `KeyboardShortcut` the menu item applies rather than typed
/// out beside it. The palette advertises what the menu bar claims, by
/// construction — a chord moved in the table moves in both places, and there is
/// no second string to forget.
enum ShortcutDisplay {
    static func string(_ shortcut: KeyboardShortcut) -> String {
        modifiers(shortcut.modifiers) + key(shortcut.key)
    }

    /// ⌃⌥⇧⌘, in that order, because that is the order macOS itself draws them
    /// in and a menu bar sitting two inches above the palette is the reference
    /// nobody can avoid comparing it to.
    private static func modifiers(_ modifiers: EventModifiers) -> String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs
    }

    /// The named keys as their glyphs, and everything else uppercased — `t`
    /// is stored lowercase because that is how a key equivalent is written,
    /// and ⌘t on a menu would mean ⇧⌘T.
    private static func key(_ key: KeyEquivalent) -> String {
        switch key.character {
        case KeyEquivalent.return.character: "↩"
        case KeyEquivalent.escape.character: "⎋"
        case KeyEquivalent.delete.character: "⌫"
        case KeyEquivalent.deleteForward.character: "⌦"
        case KeyEquivalent.tab.character: "⇥"
        case KeyEquivalent.space.character: "␣"
        case KeyEquivalent.upArrow.character: "↑"
        case KeyEquivalent.downArrow.character: "↓"
        case KeyEquivalent.leftArrow.character: "←"
        case KeyEquivalent.rightArrow.character: "→"
        case KeyEquivalent.home.character: "↖"
        case KeyEquivalent.end.character: "↘"
        case KeyEquivalent.pageUp.character: "⇞"
        case KeyEquivalent.pageDown.character: "⇟"
        default: String(key.character).uppercased()
        }
    }
}

/// One command as a menu item: the title, the chord and the greying all read
/// out of the table, so the only thing the menu bar still decides is where the
/// item sits.
struct CommandMenuItem: View {
    let id: CommandID
    let store: SessionStore

    init(_ id: CommandID, store: SessionStore) {
        self.id = id
        self.store = store
    }

    var body: some View {
        let command = Commands.command(id)
        Button(command.title(store)) { store.runCommand(id) }
            // The optional overload, so a chord-less command needs no branch
            // here. Which commands have chords is the table's business.
            .keyboardShortcut(command.shortcut)
            .disabled(!command.isEnabled(store))
    }
}

/// One choice command as a submenu: its title, its greying and its options
/// come out of the same table entry the palette's prompt reads, so the two
/// lists of machines cannot disagree.
///
/// Two levels of greying, and both are held here rather than asked of the
/// callers: the menu itself for `Command.isEnabled`, and every row in it for
/// `PaletteChoice.isEnabled` — the same flag the palette dims a row with, so
/// an option the store would refuse cannot be clicked to no effect on either
/// surface, and a choice prompt added later gets that for nothing.
///
/// The row itself is the caller's to build, because the two differ in kind.
/// Switch Host draws a `Toggle`: the checkmark on the machine you are on is
/// the only thing in the menu bar that says which one that is, and macOS draws
/// it for a toggle without being asked. Forget Host draws a `Button`, because
/// there is no state there to check and a toggle that never toggles on is a
/// lie about one.
struct CommandChoiceMenu<Row: View>: View {
    let id: CommandID
    let store: SessionStore
    @ViewBuilder let row: (PaletteChoice) -> Row

    init(_ id: CommandID, store: SessionStore, @ViewBuilder row: @escaping (PaletteChoice) -> Row) {
        self.id = id
        self.store = store
        self.row = row
    }

    var body: some View {
        let command = Commands.command(id)
        Menu(command.title(store)) {
            ForEach(Commands.choices(id, in: store)) { choice in
                // On the built row rather than inside it, so the flag reaches
                // whatever control the caller chose — `.disabled` propagates
                // down — and a `Toggle` disabled this way keeps its checkmark,
                // which is the whole point of the row it lands on.
                row(choice).disabled(!choice.isEnabled)
            }
        }
        .disabled(!command.isEnabled(store))
    }
}
