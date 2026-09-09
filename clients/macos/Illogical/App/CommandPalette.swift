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
//  Geometry, measured from the reference: 1.6× the session dropdown's width,
//  so 352pt against `MenuMetrics.width`'s 220; sixteen rows before it scrolls,
//  with the indicator visible; horizontally centred in the window with its top
//  edge just below the toolbar. Everything else — row height, padding, corner
//  radii, the field's height, the type size — is `MenuMetrics` by name rather
//  than a second set of numbers, because this panel and the dropdown are the
//  same kind of surface and a person sees them a second apart.
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

enum PaletteMetrics {
    /// 1.6× `MenuMetrics.width`, as the reference measures the panel against
    /// the dropdown it sits above. Wider than the dropdown because the rows
    /// carry two things: a title, and either the value it acts on or the chord
    /// that reaches it.
    static let width: CGFloat = 352

    /// How many rows fit before it scrolls. Sixteen is the reference's, and it
    /// is also about right for the table: the whole of it is twenty-two, so
    /// the panel is honest about there being more without becoming a window.
    static let maxRows = 16
    static let listMaxHeight = CGFloat(maxRows) * MenuMetrics.rowHeight

    /// How tall the list is for a given number of rows.
    ///
    /// Written down rather than left to the `ScrollView`, which is greedy in
    /// its scroll axis: handed the window's height to fill it takes all of it,
    /// so a filter narrowed to two rows drew a panel sixteen rows tall with
    /// fourteen rows of nothing under them. The floor of one is the "no
    /// matching commands" notice, which is a row like any other.
    static func listHeight(rows: Int) -> CGFloat {
        min(CGFloat(max(rows, 1)) * MenuMetrics.rowHeight, listMaxHeight)
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
        .frame(height: MenuMetrics.fieldHeight)
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
    /// It keeps the selected row's colours — the theme's blue with whichever
    /// terminal colour reads on it — because that is what it *is*: the row you
    /// pressed Return on, still highlighted, now living in the field.
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: PaletteMetrics.chipFont, weight: .medium))
            .foregroundStyle(Palette.menuHighlightText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, PaletteMetrics.chipPadding)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: PaletteMetrics.chipCorner, style: .continuous)
                    .fill(Palette.menuHighlight))
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
                .frame(height: MenuMetrics.rowHeight)
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
        .frame(height: MenuMetrics.rowHeight)
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
