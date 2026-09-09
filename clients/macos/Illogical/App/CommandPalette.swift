//  CommandPalette.swift
//  ⇧⌘P: everything the app can do, searchable, in one panel.
//
//      ┌────────────────────────────────────────────────┐
//      │ ⌕  Search commands...                          │  field, 22pt
//      │                                                │
//      │    Change Session             drifting-cedar › │  22pt rows
//      │    Rename Session…            drifting-cedar › │
//      │ ⇄  Switch Host                       build-box │
//      │ ⊕  Add Remote Host…                          › │
//      │    New Terminal                            ⌘T  │
//      │    Close Tab                              ⇧⌘W  │  dim: no tab
//      └────────────────────────────────────────────────┘
//
//  Return on a command that needs an argument does **not** open a submenu. The
//  panel stays exactly where it is, at the same width, and collapses to the
//  field and one line under it — the command becomes a chip inside the field
//  you were already typing in, and that field stops meaning "search commands"
//  and starts meaning "give me this command's argument":
//
//      ┌────────────────────────────────────────────────┐
//      │ [Add Host] user@host                           │
//      │────────────────────────────────────────────────│  full-width hairline
//      │      user@host, or a Host from ~/.ssh/config   │
//      └────────────────────────────────────────────────┘
//
//  A command with a *list* of answers — Switch Host, Forget Host — is the same
//  chip and the same field, now filtering, with the choices where the hint
//  would have gone and a checkmark on the one you are already on. Free text is
//  the degenerate case of that, where a sentence takes the list's place. This
//  reuses the grammar stage one already taught — the field narrows a list, the
//  arrows move through it, Return takes it — and adds no new mechanics at all,
//  which is the whole argument for it over a second panel: there is nowhere
//  else to look and nothing else to dismiss.
//
//  Geometry, measured from the reference: 300pt wide, rows 26pt tall, sixteen
//  of them before it scrolls; horizontally centred in the window with its top
//  edge just below the toolbar.
//
//  Those two numbers were 352 and 22 first, and both were wrong, which is worth
//  writing down because the error is not visible in either one alone. The panel
//  was built out of `MenuMetrics` on the reasoning that this and the dropdown
//  are the same kind of surface — so it took the dropdown's 22pt row and a
//  width guessed as a multiple of the dropdown's. Against the reference the
//  result was both too wide and too tight, and the tell is a ratio rather than
//  a measurement: width over row height is 11.7 in the reference and was 16.0
//  here. A ratio survives not knowing the reference's scale, which a screenshot
//  of a video does not tell you. Fixing it needs both numbers to move, and 300
//  ÷ 26 is 11.5.
//
//  So the panel keeps `MenuMetrics`'s padding, corner radii and type size — a
//  person sees the two surfaces a second apart and they should be cut from the
//  same cloth — but its width and its row are its own. The dropdown is a list
//  of names; this is a list of sentences with a chord or a value after them,
//  and it needs the air.
//
//  Two rulings about icons, both worth stating because both went the other way
//  once. In the **command** list an icon is inline: a row without one starts
//  its title at the text inset, and a row with one is pushed right. That is
//  what the reference does, and it is affordable here because no command's
//  glyph depends on state, so nothing ever reflows under the pointer. In the
//  **choice** list the column is reserved (`MenuMetrics.iconColumn`), because
//  there the glyph is exactly the state-dependent one — the current machine's
//  checkmark — that made the dropdown reserve its column in the first place.

import SwiftUI

/// The panel's own two colours. Everything else it draws with is `Palette`'s
/// menu set, shared with the dropdown — see `SessionMenu`.
extension Palette {
    /// The chip's fill: the terminal's own foreground, pulled a little back
    /// toward the background so it reads as a label rather than as a block of
    /// pure white. Neutral on purpose, and the one place in the panel that is
    /// deliberately *not* the accent — see `CommandPalette.chip(_:)`.
    static var paletteChip: Color { text(0.12) }

    /// On that: the terminal's background, which is the colour guaranteed to
    /// read against its foreground, because a theme that failed to do so would
    /// be unusable as a terminal long before it got here.
    static var paletteChipText: Color { background }
}

enum PaletteMetrics {
    /// Measured off the reference rather than derived from the dropdown, for
    /// the reason the file header gives: a width picked as a multiple of
    /// `MenuMetrics.width` came out half again too wide for its own rows.
    /// Wider than the dropdown all the same, because these rows carry two
    /// things — a title, and either the value it acts on or the chord that
    /// reaches it.
    static let width: CGFloat = 300

    /// Taller than `MenuMetrics.rowHeight`'s 22, and deliberately not it. The
    /// dropdown's row holds a session name; this one holds a sentence with a
    /// chord after it, and at 22 the two columns read as one crowded line.
    /// The reference's own row is the same 4pt taller.
    static let rowHeight: CGFloat = 26

    /// The field matches a row, so the panel has one vertical rhythm from the
    /// top down — the same rule `MenuMetrics.fieldHeight` follows, applied to
    /// this panel's row rather than the dropdown's.
    static let fieldHeight: CGFloat = rowHeight

    /// How many rows fit before it scrolls. Sixteen is the reference's, and it
    /// is also about right for the table: the whole of it is twenty-two, so
    /// the panel is honest about there being more without becoming a window.
    static let maxRows = 16
    static let listMaxHeight = CGFloat(maxRows) * rowHeight

    /// How tall the list is for a given number of rows.
    ///
    /// Written down rather than left to the `ScrollView`, which is greedy in
    /// its scroll axis: handed the window's height to fill it takes all of it,
    /// so a filter narrowed to two rows drew a panel sixteen rows tall with
    /// fourteen rows of nothing under them. The floor of one is the "no
    /// matching commands" notice, which is a row like any other.
    static func listHeight(rows: Int) -> CGFloat {
        min(CGFloat(max(rows, 1)) * rowHeight, listMaxHeight)
    }

    /// The command-turned-token in the field. Rounded rather than a capsule
    /// because it sits flush against the field's left inset and a capsule's
    /// end-cap would leave a crescent of field colour inside the corner.
    static let chipCorner: CGFloat = 5
    static let chipFont: CGFloat = 11
    static let chipPadding: CGFloat = 5

    /// The one line a free-text stage two draws under its hairline. Smaller
    /// than a row: it is a label, not something to click — the same rule
    /// `MenuMetrics.headerFont` follows.
    static let hintFont: CGFloat = 11
}

struct CommandPalette: View {
    @Environment(SessionStore.self) private var store

    /// What has been typed. View state, exactly as the dropdown's `filter` is:
    /// nothing outside this panel has an opinion about it, and it dies with
    /// the panel. What it *means* — which rows survive it — is the store's,
    /// through `paletteCommands(matching:)`.
    @State private var query = ""

    /// Which row is highlighted, as an index into whichever list is showing.
    /// `-1` when there is none: an empty filter result, or a stage two whose
    /// list is a sentence.
    @State private var selected = -1

    /// The row an *arrow* asked to be scrolled into view.
    ///
    /// Separate from `selected` because hovering also moves the highlight and
    /// must not scroll: the pointer is already on the row, and scrolling under
    /// it would fight the wheel that put it there. Hovering clears this, so
    /// that arrowing back onto the same row afterwards still scrolls to it.
    @State private var scrollTarget: String?

    @FocusState private var fieldFocused: Bool

    /// Stage one whenever the panel is up at all. The `??` is unreachable —
    /// `ContentView` only builds this view while `store.palette` is non-nil —
    /// and is here so that the one frame between a dismissal and the removal
    /// transition finishing draws the panel it was already drawing rather than
    /// trapping.
    private var stage: PaletteStage { store.palette ?? .commands }

    /// The prompt in play, or nil in stage one.
    private var prompt: Command.Prompt? { stage.argument.flatMap { Commands.prompt($0) } }

    private var commands: [Command] { store.paletteCommands(matching: query) }

    /// The options stage two is offering. Empty in stage one, and empty for a
    /// free-text stage two — which is what leaves the hint as the only thing
    /// under the hairline.
    private var choices: [PaletteChoice] {
        guard let id = stage.argument else { return [] }
        return store.paletteChoices(for: id, matching: query)
    }

    private var isChoosing: Bool { stage.argument != nil }

    /// The ids of the list currently under the field, in its order. One list
    /// of strings for both stages, so the selection, the scroll and the reset
    /// are one rule rather than a pair that could disagree about which row is
    /// first.
    private var rowIDs: [String] {
        isChoosing ? choices.map(\.id) : commands.map(\.id.rawValue)
    }

    /// Which of those rows can actually be run. Every choice can: the options
    /// a prompt offers are already only the machines the command applies to.
    private var enabled: [Bool] {
        isChoosing ? choices.map { _ in true } : commands.map { $0.isEnabled(store) }
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if let prompt {
                hairline
                argument(prompt)
            } else {
                // The dropdown's own gap between its field and its rows, by
                // name. On the list rather than on the field because stage two
                // has a gap already — the hairline's own vertical padding —
                // and both would be an eccentric fourteen points of air above
                // a hairline with six below it.
                commandList
                    .padding(.top, MenuMetrics.fieldToRows)
            }
        }
        .padding(MenuMetrics.padding)
        .frame(width: PaletteMetrics.width)
        .background {
            RoundedRectangle(cornerRadius: MenuMetrics.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Palette.menuTop, Palette.menuBottom],
                        startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MenuMetrics.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.menuStroke, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
        // Everything in the panel is something to click, so the whole panel is
        // an arrow. The field puts the I-beam back over itself.
        .cursor(.arrow)
        .onAppear {
            fieldFocused = true
            resetSelection()
        }
        // A stage change is a new question, so what was typed for the old one
        // goes. Here rather than in the store because the text is this view's;
        // the store's invariant says only that it resets, not who does it.
        //
        // Guarded on the new value because a *dismissal* is not a stage change,
        // and this view is still mounted when one happens: the overlay's ZStack
        // is unconditional so the removal transition has something to run
        // inside. So on Escape, `ContentView.returnFocusIfNothingIsOpen` bumps
        // `focusGeneration` to hand the keyboard back to the terminal while
        // this line would be asking a field inside the disappearing panel to
        // take it — W15's bug from the other side, two writes fighting over
        // first responder. `nil → .commands` still passes the guard, which is
        // right: opening is a stage change and wants the reset.
        //
        // Nothing below `ContentView` can be driven from a unit test, so this
        // is not pinned by one.
        .onChange(of: store.palette) { _, stage in
            guard stage != nil else { return }
            query = ""
            resetSelection()
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in resetSelection() }
        // Escape closes it, the way it closes an NSMenu. Not `.onExitCommand`,
        // for the reason `EscapeKey` sets out at length: that fires only for
        // the *focused* view, and with an overlay up the app's focused element
        // is reliably still the terminal surface underneath.
        .onEscape { store.closePalette() }
        .onPaletteKey { keyCode, modifiers in
            switch PaletteKeys.claim(
                keyCode: keyCode, modifiers: modifiers, stageIsArgument: isChoosing,
                queryIsEmpty: query.isEmpty)
            {
            case .pass: return false
            case .up:
                move(by: -1)
                return true
            case .down:
                move(by: 1)
                return true
            case .popArgument:
                store.popPaletteArgument()
                return true
            }
        }
    }

    // MARK: - The field

    private var field: some View {
        HStack(spacing: 6) {
            if let prompt {
                chip(prompt.chip)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.menuShortcut)
            }

            TextField(prompt?.placeholder ?? "Search commands...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: MenuMetrics.font))
                .foregroundStyle(Palette.menuText)
                .focused($fieldFocused)
                .onSubmit(commit)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(height: PaletteMetrics.fieldHeight)
        .background(
            // A rounded rect where the dropdown's filter field is a capsule.
            // The chip sits flush at this field's left inset, and a capsule's
            // end-cap would leave a crescent of field colour inside its corner.
            RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                .fill(Palette.menuField)
                .overlay(
                    RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        )
        // The one part of the panel that is text to type in rather than
        // something to click, so it opts back out of the arrow above.
        .cursor(.iBeam)
    }

    /// The command, collapsed into the field it was chosen from.
    ///
    /// Neutral rather than the selected row's accent, which is what this was
    /// first, on the reasoning that the chip *is* the row you pressed Return
    /// on and should stay highlighted. The reference says otherwise and is
    /// right: in the panel the accent means "this is what Return will take",
    /// and by the time there is a chip that question is settled — the accent
    /// would be pointing at a decision already made, next to a field where
    /// Return now means something else entirely. So the chip reads as a label
    /// on the field, not as a selection in a list.
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: PaletteMetrics.chipFont, weight: .medium))
            .foregroundStyle(Palette.paletteChipText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, PaletteMetrics.chipPadding)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: PaletteMetrics.chipCorner, style: .continuous)
                    .fill(Palette.paletteChip))
    }

    // MARK: - Stage one

    private var commandList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        let isEnabled = command.isEnabled(store)
                        PaletteRow(
                            icon: command.icon,
                            title: command.title(store),
                            trailing: trailing(command),
                            chevron: isPrompt(command),
                            isSelected: selected == index,
                            isEnabled: isEnabled,
                            // A dimmed row does not take the highlight either.
                            // One highlight, and it is always on something
                            // Return would actually do.
                            hover: { inside in
                                guard inside, isEnabled else { return }
                                selected = index
                                scrollTarget = nil
                            },
                            action: { store.runCommand(command.id) }
                        )
                        .id(command.id.rawValue)
                    }

                    if commands.isEmpty {
                        MenuNotice(text: "No matching commands")
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(height: PaletteMetrics.listHeight(rows: commands.count))
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target)
            }
        }
    }

    /// The right-hand end of a row: the value the command acts on, or the
    /// chord that reaches it.
    ///
    /// The value wins when a command has both. "Which session am I about to
    /// rename" is the more useful of the two answers at the moment somebody is
    /// reading the row, and the chord is on the menu item two inches above.
    private func trailing(_ command: Command) -> String? {
        if let detail = command.detail?(store) { return detail }
        return command.shortcut.map(ShortcutDisplay.string)
    }

    private func isPrompt(_ command: Command) -> Bool {
        if case .prompt = command.action { return true }
        return false
    }

    // MARK: - Stage two

    @ViewBuilder
    private func argument(_ prompt: Command.Prompt) -> some View {
        if case .choice = prompt.kind {
            choiceList
        } else if let hint = prompt.hint {
            Text(hint)
                .font(.system(size: PaletteMetrics.hintFont))
                .foregroundStyle(Palette.menuShortcut)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: PaletteMetrics.rowHeight)
        }
    }

    private var choiceList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                        PaletteRow(
                            // Reserved rather than inline, unlike the command
                            // list: the checkmark comes and goes with which
                            // machine you are on, and an icon that appears
                            // would shift every title beside it.
                            icon: choice.isCurrent ? "checkmark" : nil,
                            reservesIcon: true,
                            title: choice.title,
                            isSelected: selected == index,
                            isEnabled: true,
                            hover: { inside in
                                guard inside else { return }
                                selected = index
                                scrollTarget = nil
                            },
                            action: { store.chooseOption(choice) }
                        )
                        .id(choice.id)
                    }

                    if choices.isEmpty {
                        MenuNotice(text: "No matching hosts")
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(height: PaletteMetrics.listHeight(rows: choices.count))
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target)
            }
        }
    }

    /// The full width of the panel, edge to edge.
    ///
    /// Deliberately not `MenuSeparator`: its inset is the dropdown's, where a
    /// hairline divides rows that are themselves inset from the panel. The
    /// reference draws this one right across, because what it divides is not
    /// two rows but two halves of the panel's job.
    private var hairline: some View {
        Rectangle()
            .fill(Palette.menuSeparator)
            .frame(height: 1)
            .padding(.horizontal, -MenuMetrics.padding)
            .padding(.vertical, MenuMetrics.separatorPadding)
    }

    // MARK: - Selection

    private func resetSelection() {
        // From before the list, stepping forward: the first row that can
        // actually be run. A filter whose first match is dimmed used to leave
        // the highlight on it, and Return then did nothing at all.
        selected = PaletteKeys.step(from: -1, by: 1, enabled: enabled)
        scrollTarget = selectedID
    }

    private func move(by delta: Int) {
        selected = PaletteKeys.step(from: selected, by: delta, enabled: enabled)
        scrollTarget = selectedID
    }

    private var selectedID: String? {
        rowIDs.indices.contains(selected) ? rowIDs[selected] : nil
    }

    /// Return.
    ///
    /// Into the store in every case, which is what keeps a keystroke and a
    /// click doing the same thing. Where the *guard* sits differs by branch,
    /// and it is worth being exact about, because only the first one goes
    /// through `runCommand`:
    ///
    /// Stage one is `runCommand`, so the enabled check is that method's and a
    /// dimmed row's Return does nothing. The choice branch has no check to
    /// make — every option a prompt offers can be taken, because the options
    /// are already only the machines the command applies to.
    ///
    /// The text branch calls the prompt's own commit directly, and its guard is
    /// therefore the *action's*: `commitAddHost` owns the trim and the refusal
    /// of an empty destination, and `.addRemoteHost` is unconditionally enabled
    /// today so there is no predicate to have skipped. That is invariant 1's
    /// belt-and-braces framing at `SessionStore.palette` — the stage is only
    /// ever entered through an enabled command, and every action re-guards for
    /// itself anyway. A free-text prompt added later that *does* carry a
    /// predicate has to bring a store action which re-checks it, the way
    /// `switchHost` and `removeHost` already do.
    private func commit() {
        guard let id = stage.argument, let prompt = Commands.prompt(id) else {
            guard commands.indices.contains(selected) else { return }
            store.runCommand(commands[selected].id)
            return
        }
        switch prompt.kind {
        case .text(let commit):
            commit(store, query)
        case .choice:
            guard choices.indices.contains(selected) else { return }
            store.chooseOption(choices[selected])
        }
    }
}

/// One row of either list.
///
/// Not `MenuRow`: that one has no notion of being disabled, no chevron, and a
/// reserved icon column it cannot be talked out of — and giving it three more
/// flags would make the dropdown's rows pay for the palette's.
private struct PaletteRow: View {
    var icon: String?
    /// Whether the leading glyph gets a column of its own whether or not there
    /// is one. False in the command list, where icons are inline because no
    /// command's glyph moves; true in the choice list, where the checkmark
    /// does.
    var reservesIcon = false
    let title: String
    var trailing: String?
    var chevron = false
    let isSelected: Bool
    let isEnabled: Bool
    let hover: (Bool) -> Void
    let action: () -> Void

    /// Dimmed rather than hidden, and the difference matters: the menu bar
    /// greys these items and the dropdown's context menu greys them and says
    /// why. Hiding them would make the palette lie about what the app can do,
    /// and leave somebody searching for a command that is right there.
    private var titleColor: Color {
        guard isEnabled else { return Palette.menuShortcut }
        return isSelected ? Palette.menuHighlightText : Palette.menuText
    }

    private var trailingColor: Color {
        guard isEnabled, isSelected else { return Palette.menuShortcut }
        return Palette.menuHighlightText.opacity(0.7)
    }

    var body: some View {
        HStack(spacing: 0) {
            if reservesIcon || icon != nil {
                Group {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11))
                    }
                }
                .frame(width: MenuMetrics.iconColumn, alignment: .center)

                Spacer().frame(width: MenuMetrics.iconToTitle)
            }

            Text(title)
                .font(.system(size: MenuMetrics.font))
                .lineLimit(1)

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.system(size: MenuMetrics.font))
                    .lineLimit(1)
                    .foregroundStyle(trailingColor)
            }

            // The reference's `>`: this command will ask you something rather
            // than doing it. Only ever on a row that has a prompt behind it, so
            // it is a promise the panel keeps.
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(trailingColor)
                    .padding(.leading, 6)
            }
        }
        .foregroundStyle(titleColor)
        .padding(.horizontal, MenuMetrics.rowPadding)
        .frame(height: PaletteMetrics.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(Palette.menuHighlight)
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: hover)
        // A dimmed row takes no click. The store re-guards anyway; this is so
        // that clicking one is visibly nothing rather than a panel that closes
        // and does not act.
        .onTapGesture { if isEnabled { action() } }
    }
}
