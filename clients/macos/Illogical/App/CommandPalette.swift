//  CommandPalette.swift
//  ⇧⌘P: everything the app can do, searchable, in one panel.
//
//      ┌────────────────────────────────────────────────┐
//      │ ⌕  Search commands...                          │  field, 25pt
//      │                                                │
//      │    Change Session             drifting-cedar › │  25pt rows
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
//  would have gone. Every row in that list is somewhere Return can actually
//  take you: Switch Host leaves out the machine you are already on and Forget
//  Host leaves out the local daemon, because the store refuses both and a row
//  whose Return does nothing is the thing this panel keeps killing. Free text
//  is the degenerate case of it, where a sentence takes the list's place. This
//  reuses the grammar stage one already taught — the field narrows a list, the
//  arrows move through it, Return takes it — and adds no new mechanics at all,
//  which is the whole argument for it over a second panel: there is nowhere
//  else to look and nothing else to dismiss.
//
//  Geometry: 290pt wide, rows 25pt at 13pt type, hanging 30pt under the toolbar
//  and centred in the window. Every one of those is the reference's own number,
//  not a proportion of it — see below for why that distinction cost four
//  rounds.
//
//  The reference is a photograph of a screen, so it carries no scale of its
//  own until something in the frame supplies one. The traffic lights do: their
//  centres are 20pt apart on every Mac and measure 24.5px there, giving
//  **1.225 px/pt**, confirmed by their diameters coming back at ~12pt as they
//  must. The photograph is also verifiably rectilinear — the window's top edge
//  holds y=24 from x=200 to x=1200, flat to under a pixel, which no rotation,
//  keystone or lens distortion could leave alone. So the frame can be measured
//  across, not just locally, and these came out of it: highlight 342px, row
//  pitch 30.0px, cap height 11.5px, panel ~357px counting its padding.
//
//  What went wrong before is worth keeping, because it was not an arithmetic
//  error. The panel was first built out of `MenuMetrics` at 352×22 — ratio
//  16.0 against the reference's 11.7 — and correcting *that* gave 340×29,
//  which held the ratio to within a fifth of a percent and was within fifty
//  points of the reference's actual width. It was right, and it was reported
//  as too small, so it was scaled to 440×36 and then aimed at 422×36 at 19pt
//  type, each step holding the proportions and drifting further from the size.
//
//  The premise under all of that was that the reference is a fullscreen app,
//  so the palette should occupy the same *fraction* of the window. It is not:
//  its window measures 1025pt with desktop visible on three sides, which is
//  smaller than the window this was being compared in. The palette reads large
//  there because the window is small. A fixed-width panel cannot hold a
//  fraction anyway — the same 440 was 25% of one window and 33% of the same
//  window resized — so the fraction was never a property of the palette to
//  copy. The absolute size is.
//
//  The panel still takes `MenuMetrics`'s padding and corner radii, because a
//  person sees the two surfaces a second apart and they should be cut from the
//  same cloth. Only the width, the row and the leading inset are its own, and
//  each is measured rather than derived.
//
//  Icons are inline in both lists: a row without one starts its title at the
//  text inset, and a row with one is pushed right. No glyph in either list ever
//  appears or disappears in place, so nothing reflows under the pointer.
//
//  Holding that for the **choice** list took moving its one state-dependent
//  glyph — a checkmark on the machine you are on — to the trailing side. It
//  was a reserved leading column first, which is the dropdown's answer and a
//  defensible one, because a checkmark that comes and goes on the left would
//  shift every title beside it. But reserving indents a whole list to make room
//  for one glyph, and the reference's choice rows begin exactly where its
//  command rows do. Trailing satisfies both: nothing on the left can move
//  because nothing is on the left, and the column it lands in is empty in a
//  choice row anyway.
//
//  No list draws that checkmark today — the one machine it could mark is the
//  one Switch Host leaves out, a paragraph above — and the argument is kept
//  because the glyph and its column are: see `PaletteChoice.isCurrent`.

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
    /// The reference's own width, measured rather than proportioned: its
    /// highlight is 342px and its scroller ends at 834, which with the panel's
    /// padding puts the panel at ~357px, or 290 at 1.225px/pt.
    ///
    /// Still wider than the dropdown's 220, because these rows carry two things
    /// — a title, and either the value it acts on or the chord that reaches
    /// it — where a dropdown row carries a session name.
    static let width: CGFloat = 290

    /// Taller than `MenuMetrics.rowHeight`'s 22, and deliberately not it. The
    /// dropdown's row holds a session name; this one holds a sentence with a
    /// chord after it, and at 22 the two columns read as one crowded line.
    ///
    /// 25 is the reference's row pitch — baselines 30.0px apart at 1.225px/pt.
    /// Its highlight is shorter than that again, 27px against the 30, so the
    /// fill is inset a point or so top and bottom where ours fills the row.
    /// Left alone: the fill only ever abuts another fill when two rows are
    /// selected at once, and only one ever is.
    static let rowHeight: CGFloat = 25

    /// The same 13 the dropdown sets, and measured to be so rather than
    /// inherited: the reference's cap height is 11.5px, which at 1.225px/pt and
    /// SF Pro's 0.73 cap ratio is 12.8pt of type. The ratio was checked against
    /// this app at a known size before it was trusted on a photograph.
    static let font: CGFloat = 13

    /// How far under the toolbar the panel hangs.
    ///
    /// Not the dropdown's 1pt. That panel is a menu belonging to the session
    /// button and has to touch what it drops from; this one belongs to the
    /// window, and the reference floats it clear of the chrome — below the
    /// pane header rather than tucked behind it, so the top of the window
    /// still reads as the window's.
    ///
    /// 30 because that is where the reference puts it: its panel starts about
    /// 36px below the toolbar's lower edge, which is 29.4pt.
    static let topInset: CGFloat = 30

    /// The field matches a row, so the panel has one vertical rhythm from the
    /// top down — the same rule `MenuMetrics.fieldHeight` follows, applied to
    /// this panel's row rather than the dropdown's.
    static let fieldHeight: CGFloat = rowHeight

    /// How many rows fit before it scrolls. Sixteen is the reference's, and it
    /// is also about right for the table: the whole of it is twenty-two, so
    /// the panel is honest about there being more without becoming a window.
    ///
    /// A ceiling on the table, and not a promise about the panel. Sixteen 25pt
    /// rows are 400pt of list in a 441pt panel, and a panel that hangs 30pt
    /// down and leaves the same margin beneath it needs 501pt of content area
    /// — where `ContentView` lets a window be 460pt tall. So the room actually
    /// there is the other limit, and `listHeight(rows:in:)` takes whichever of
    /// the two bites first.
    static let maxRows = 16
    static let listMaxHeight = CGFloat(maxRows) * rowHeight

    /// The lane the scroller sits in, held clear of the rows.
    ///
    /// The reference's scrollbar covers no text: it has a little of its own
    /// space at the right and stays there. Without this the overlay scroller
    /// draws straight over the trailing column, which is where every chord and
    /// every value in the panel is — so the one thing it obscures is the one
    /// thing the row's right-hand side exists to say.
    ///
    /// Reserved from the rows rather than added to the panel, so the width
    /// above stays the measured number and the lane comes out of it.
    ///
    /// Taken out of the row's *text* rather than out of the row, which is the
    /// distinction that matters: insetting the whole row pulled its highlight
    /// in on the right and left it out on the left, and a selected row that is
    /// off-centre in its own panel looks like a mistake even when nobody can
    /// say why. The fill spans the row; only what it contains stops short.
    ///
    /// Ten, and not scaled with anything: the scroller in it is the system's
    /// and is a fixed physical width whatever this panel does. The reference's
    /// is 7px — 5.7pt — so ten is that plus a little air, which is what the
    /// lane is for.
    static let scrollGutter: CGFloat = 10

    /// The row's left inset, wider than `MenuMetrics.rowPadding`'s 7.
    ///
    /// The dropdown can be tight against its edge because its rows are short
    /// names; here a title starts a sentence, and at 7 it began hard against
    /// the highlight's own corner radius — the fill's curve and the first
    /// letter fighting for the same few points.
    ///
    /// The reference measures 8.2pt from the highlight's edge to the first ink
    /// of the title, and a glyph carries a little left side bearing ahead of
    /// its ink, so the true inset there is nearer 8. Nine rather than eight
    /// because 7 was looked at and rejected, and a point the other side of the
    /// measurement is worth more than a point of false precision on a
    /// photograph.
    static let rowLeading: CGFloat = 9

    /// Everything in the panel that is not the list: the padding above and
    /// below it, the field, and the gap under the field. Written down because
    /// the height clamp has to subtract it.
    static let listOverhead: CGFloat =
        2 * MenuMetrics.padding + fieldHeight + MenuMetrics.fieldToRows

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

    /// The same, in a window with `available` points of content under its
    /// title bar — which is the area the panel is centred in, and the only
    /// limit `maxRows` cannot express.
    ///
    /// Sixteen rows is a count, not a height, and it stopped being a safe one
    /// when the row went to 36: the panel that makes is 628pt tall and hangs
    /// 36pt down, so any window shorter than that got a palette running off the
    /// bottom edge — with the last commands in the table unreachable, because
    /// arrowing onto one scrolls it into a part of the list that is outside the
    /// window too. So there are two ceilings now and the list takes whichever
    /// bites first.
    ///
    /// Rounded down to whole rows, so the list is always an exact number of
    /// them rather than ending in a sliver of one, and floored at a single row
    /// for the reason the count is: a window too short even for that is better
    /// served by a panel that overflows than by one with nothing in it.
    ///
    /// The margin left at the bottom is `topInset` again. The panel hangs that
    /// far below the chrome, and stopping the same distance above the bottom
    /// edge is what makes a clamped panel look placed rather than cropped.
    ///
    /// A height of zero is a container SwiftUI has not laid out yet, which it
    /// reports for a frame or two; clamping against it would open every palette
    /// one row tall and then snap it open.
    static func listHeight(rows: Int, in available: CGFloat) -> CGFloat {
        guard available > 0 else { return listHeight(rows: rows) }
        let room = available - 2 * topInset - listOverhead
        return min(listHeight(rows: rows), max((room / rowHeight).rounded(.down), 1) * rowHeight)
    }

    /// The command-turned-token in the field. Rounded rather than a capsule
    /// because it sits flush against the field's left inset and a capsule's
    /// end-cap would leave a crescent of field colour inside the corner.
    ///
    /// Its type is two points under the row's: the chip says what the field has
    /// become, and set at `font` it would carry the same weight as the answer
    /// being typed beside it.
    static let chipCorner: CGFloat = 5
    static let chipFont: CGFloat = 11
    static let chipPadding: CGFloat = 6

    /// The one line a free-text stage two draws under its hairline. Smaller
    /// than a row: it is a label, not something to click — the same rule
    /// `MenuMetrics.headerFont` follows, and the same size the chip is set at,
    /// so the two things in the panel that are not rows agree with each other.
    static let hintFont: CGFloat = 11
}

struct CommandPalette: View {
    @Environment(SessionStore.self) private var store

    /// How much window there is to draw in: the height of the content area the
    /// panel is centred in, which is what its list clamps against.
    ///
    /// Handed in rather than measured here, because the only instrument this
    /// view has is a `GeometryReader` and a `GeometryReader` fills whatever it
    /// is offered — measuring the window would make the panel the size of it.
    /// `ContentView` is the one placing this and already holds the number.
    let windowHeight: CGFloat

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
    /// it would fight the wheel that put it there. A hover clears this, so that
    /// arrowing back onto the same row afterwards still scrolls to it.
    ///
    /// That was considered in one direction only, and the other one was a bug.
    /// A `scrollTo` moves the list under a pointer that has not moved, which
    /// fires the hover of whichever row lands beneath it — so an arrow past the
    /// visible fold set this, scrolled, and had its own selection snapped back
    /// and this cleared by the row that arrived. `PaletteKeys.hoverMoved` is
    /// what stops a hover the mouse did not cause from counting; both writes
    /// below are behind it.
    @State private var scrollTarget: String?

    /// Where the pointer was when this panel last heard from it, in window
    /// coordinates. Nil until it is heard from at all.
    ///
    /// The whole of the hover rule's memory — see `PaletteKeys.hoverMoved` for
    /// what it is for and why the space it is measured in has to be one the
    /// panel does not move in.
    @State private var pointer: CGPoint?

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
                // The hairline belongs to the *sentence* under a free-text
                // prompt, not to a list. A hint is one line floating in an
                // otherwise empty panel and needs something to hold it away
                // from the field; a list already reads as a list, and a rule
                // drawn over the top of one that scrolls underneath it looks
                // like a seam in the panel. The reference draws it in the
                // first case and not in the second.
                if case .choice = prompt.kind {
                    argument(prompt)
                        .padding(.top, MenuMetrics.fieldToRows)
                } else {
                    hairline
                    argument(prompt)
                }
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
                // Opaque, and not for want of trying. A blurred panel is what
                // macOS does with this kind of surface and it was built twice
                // — `.ultraThinMaterial`, then an `NSVisualEffectView` at
                // `.withinWindow` — and neither blurs anything, because there
                // is nothing of *SwiftUI's* behind this panel to blur. The
                // terminal is a `CAMetalLayer` that composites on its own, and
                // the view tree knows it only as an opaque hole; both effects
                // faithfully blurred the empty background behind that hole and
                // returned a grey cast for the trouble. Getting a real one
                // means giving the panel the terminal's own texture to sample,
                // which is renderer work and a long way from a menu.
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
        // And a row can dim while the highlight is *on* it, with nothing typed
        // and nothing moved: Delete Session… when its machine drops mid-panel,
        // or Close Tab when the last tab is closed by the titlebar's own ✕,
        // which stays live under the panel because the scrim is on the content
        // view and the toolbar is not. Return then did nothing at all — the
        // case `resetSelection` says it exists to prevent, arriving from the
        // one direction it does not watch, since the filter has not changed.
        //
        // Unconditional because `restep` is: a highlight still on something
        // runnable is handed straight back, and `scrollTarget` reassigned to
        // the id it already held wakes nothing up.
        .onChange(of: enabled) { _, enabled in
            selected = PaletteKeys.restep(from: selected, enabled: enabled)
            scrollTarget = selectedID
        }
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
                // The same 11 the dropdown sets its filter glyph at, against
                // the same 13pt field type — `MenuMetrics.font` and
                // `PaletteMetrics.font` are one number. It was 12 for the
                // rounds when this field's type was 15, where a glyph left at
                // 11 read as faint rather than as small; the type came back to
                // the dropdown's and this came back with it.
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.menuShortcut)
            }

            TextField(prompt?.placeholder ?? "Search commands...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: PaletteMetrics.font))
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
            // The border is the theme's own hairline rather than white at 6%,
            // which is what made this read as a drawn box instead of a field:
            // a flat white edge on a dark panel is a rectangle you notice,
            // where the system's own search fields are a fill with barely an
            // edge at all. `menuStroke` is that hairline, and it is the
            // panel's, so field and panel are outlined by the same pen.
            RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                .fill(Palette.menuField)
                .overlay(
                    RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                        .strokeBorder(Palette.menuStroke, lineWidth: 1))
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
                            //
                            // And only a hover the *mouse* caused — see
                            // `pointerMoved(to:)`.
                            hover: { point in
                                guard isEnabled, pointerMoved(to: point) else { return }
                                selected = index
                                scrollTarget = nil
                            },
                            action: { store.runCommand(command.id) }
                        )
                        .id(command.id.rawValue)
                    }

                    if commands.isEmpty {
                        // Given the palette's row rather than the dropdown's,
                        // because the list reserves one for it — `listHeight`'s
                        // floor — and `MenuNotice`'s own 22 in that 25pt slot
                        // sat high, with all three of the leftover points
                        // underneath it. Only the height: its type is
                        // `MenuMetrics.font`, which is the same 13 this panel
                        // sets, so the two surfaces already agree about the
                        // notice's text and differed only about the row it
                        // sits in.
                        MenuNotice(text: "No matching commands")
                            .frame(height: PaletteMetrics.rowHeight)
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(
                height: PaletteMetrics.listHeight(rows: commands.count, in: windowHeight)
            )
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
                            title: choice.title,
                            // Trailing, so these rows begin where the command
                            // rows do — see `PaletteRow.trailingIcon`.
                            trailingIcon: choice.isCurrent ? "checkmark" : nil,
                            isSelected: selected == index,
                            isEnabled: true,
                            hover: { point in
                                guard pointerMoved(to: point) else { return }
                                selected = index
                                scrollTarget = nil
                            },
                            action: { store.chooseOption(choice) }
                        )
                        .id(choice.id)
                    }

                    if choices.isEmpty {
                        // The palette's row, for the reason the command list's
                        // notice takes it.
                        MenuNotice(text: "No matching hosts")
                            .frame(height: PaletteMetrics.rowHeight)
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(height: PaletteMetrics.listHeight(rows: choices.count, in: windowHeight))
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
        //
        // The rows changing is only half of that. A row can also dim where it
        // stands, with the filter untouched, and this never runs for it — see
        // the `.onChange(of: enabled)` above, which is the same rule for the
        // other half.
        selected = PaletteKeys.step(from: -1, by: 1, enabled: enabled)
        scrollTarget = selectedID
    }

    private func move(by delta: Int) {
        selected = PaletteKeys.step(from: selected, by: delta, enabled: enabled)
        scrollTarget = selectedID
    }

    /// Whether a hover reported at `point` is the mouse having moved, noting
    /// where it now is either way.
    ///
    /// The note happens on every hover, including the ones that do not count:
    /// a row arriving under a still pointer is exactly how this view learns
    /// where that pointer is, and refusing to remember it would leave the
    /// first *real* move with nothing to be different from.
    private func pointerMoved(to point: CGPoint) -> Bool {
        defer { pointer = point }
        return PaletteKeys.hoverMoved(from: pointer, to: point)
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
    let title: String
    var trailing: String?
    /// A glyph after the title rather than before it — the checkmark a choice
    /// row would carry on the option you are already on, which today is a
    /// checkmark no list draws: see `PaletteChoice.isCurrent` for why the one
    /// machine that could take it is the one Switch Host does not offer.
    ///
    /// It was a reserved *leading* column first, on the reasoning that a
    /// checkmark which comes and goes would otherwise shift every title beside
    /// it. That reasoning is sound and the conclusion was still wrong: the
    /// reference's choice rows begin exactly where its command rows do, and
    /// reserving a column ahead of them indents a whole list to make room for
    /// one glyph. Putting it on the trailing side answers both — nothing on
    /// the left ever moves, because nothing is on the left, and the column it
    /// lands in is empty in a choice row anyway.
    var trailingIcon: String?
    var chevron = false
    let isSelected: Bool
    let isEnabled: Bool
    /// The pointer is over this row, and here is where the pointer is.
    ///
    /// A position rather than the `Bool` `.onHover` would hand over, because
    /// whether this hover means anything is not a question the row can answer
    /// — see `PaletteKeys.hoverMoved`. The row reports; the panel decides.
    let hover: (CGPoint) -> Void
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
            if let icon {
                // The dropdown's pair exactly: an 11pt glyph against 13pt
                // titles, centred in `MenuMetrics`'s own 13pt column. Nothing
                // in the row's *type* is this panel's — only the row is taller
                // — and a glyph scaled to the row rather than to the text
                // would be a glyph that disagreed with the title beside it.
                //
                // The column is the dropdown's for a reason of its own: what
                // it does is line the titles up, and it does that at any glyph
                // size, so widening it would push every title with an icon
                // away from every title without one to no purpose.
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: MenuMetrics.iconColumn, alignment: .center)

                Spacer().frame(width: MenuMetrics.iconToTitle)
            }

            Text(title)
                .font(.system(size: PaletteMetrics.font))
                .lineLimit(1)

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.system(size: PaletteMetrics.font))
                    .lineLimit(1)
                    .foregroundStyle(trailingColor)
            }

            // The leading icon's 11, and semibold where that one is regular: a
            // checkmark is read against the name it marks rather than as a
            // symbol of its own, and at the same weight as the icons on the
            // other side of the row it reads as tentative — which is the one
            // thing a mark saying "you are here" must not be.
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(trailingColor)
            }

            // The reference's `>`: this command will ask you something rather
            // than doing it. Only ever on a row that has a prompt behind it, so
            // it is a promise the panel keeps. Deliberately the smallest glyph
            // in the row, two points under the icons either side of it: it is
            // punctuation on a 13pt line rather than a symbol anybody reads,
            // and it is the one thing in the row that should be noticed only
            // when it is looked for. Semibold so that two points down is quiet
            // rather than faint.
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(trailingColor)
                    .padding(.leading, 6)
            }
        }
        .foregroundStyle(titleColor)
        // Asymmetric, and the two sides are asymmetric for different reasons.
        // The left is simply wider than the dropdown's — see `rowLeading`. The
        // right carries the scroller's lane as well as its own padding, so the
        // trailing column stops clear of a scrollbar that would otherwise sit
        // on top of it.
        //
        // Both are inside the frame, so neither moves the highlight: the fill
        // below spans the whole row and stays centred in the panel however far
        // in the text has to start.
        .padding(.leading, PaletteMetrics.rowLeading)
        .padding(.trailing, MenuMetrics.rowPadding + PaletteMetrics.scrollGutter)
        .frame(height: PaletteMetrics.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: MenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(Palette.menuHighlight)
            }
        }
        .contentShape(Rectangle())
        // `.onContinuousHover` rather than `.onHover`, for the location: the
        // panel needs to know whether the mouse moved, and "the pointer is
        // inside me" cannot say. `.global` because the row itself slides when
        // the list scrolls, so a position measured inside the row changes
        // while the pointer is still — which is the one case this exists to
        // recognise. `.ended` is dropped: a row the pointer has left has
        // nothing to say about the highlight, exactly as `inside == false`
        // had nothing to say before.
        .onContinuousHover(coordinateSpace: .global) { phase in
            guard case .active(let point) = phase else { return }
            hover(point)
        }
        // A dimmed row takes no click. The store re-guards anyway; this is so
        // that clicking one is visibly nothing rather than a panel that closes
        // and does not act.
        .onTapGesture { if isEnabled { action() } }
    }
}
