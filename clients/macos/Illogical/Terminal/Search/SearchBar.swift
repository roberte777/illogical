//  SearchBar.swift
//  The find bar, floating over the terminal it is searching.
//
//      ╭──────────────────────────────────────────────╮
//      │ open                       1/2 │  ∧   ∨   ✕  │
//      ╰──────────────────────────────────────────────╯
//
//  Matched to the find bar in the reference recording, down to the parts that
//  are easy to get backwards: the query sits at the left with nothing in front
//  of it (no magnifying glass), the count and the three buttons are at the
//  right with a hairline between them, and the panel is a flat fill that is
//  *lighter* than the terminal under it. That last one is what makes it read
//  as floating; a first draft used the toolbar colour, which is darker than
//  the terminal because it sits outside it, and the bar looked like a hole.
//
//  Over the surface rather than above it, and that is the whole design: a bar
//  that pushed the grid down would resize the PTY — a `winsize` change, an
//  ANSI resize to every program in the terminal, and a reflow of the screen
//  you are searching — every time ⌘F is pressed. Floating costs nothing and
//  reflows nothing.
//
//  The price of floating is that the bar covers something, and the one thing
//  it must not cover is the match it has just taken you to. So it dodges:
//  `SearchNudge` says how far down it has to go to be clear of that match, and
//  the move is animated because a bar that teleports as you type reads as a
//  glitch rather than as a bar getting out of the way.

import SwiftUI

struct SearchBar: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: SearchSession
    /// The surface's own size, which is the space `selectedMatchRect` is in.
    let surface: CGSize

    @FocusState private var fieldFocused: Bool

    /// Sized off the reference, in the one unit that survives not knowing what
    /// font size the recording was made at: rows of its own terminal. The bar
    /// there is 56 px tall against a 23 px row pitch — **2.43 rows** — and 10.8
    /// times as wide as it is tall.
    ///
    /// So the bar is a function of the row height rather than a pair of magic
    /// numbers, and it keeps the reference's proportions at any font size. That
    /// is not future-proofing for its own sake: the app is growing a font
    /// setting, and a find bar pinned to 41 pt would be two rows tall at one
    /// size and one row at another.
    ///
    /// It is worth saying why the height was wrong before, because the bug was
    /// invisible in review: it was applied to a frame *around* the `HStack`,
    /// while the fill was a `.background` on the stack itself, which sizes to
    /// its content. The panel painted at 22 pt inside a 32 pt box and looked
    /// correct from every direction except the screen. The frame is inside
    /// `bar` now, under the fill.
    enum Metrics {
        /// Bar height in terminal rows, and width as a multiple of that height.
        static let rowsTall: CGFloat = 2.43
        static let aspect: CGFloat = 10.8
        /// What to assume before a surface has reported its grid. The 13 pt
        /// default face, whose line height is 17 pt.
        static let assumedRowHeight: CGFloat = 17

        /// From the top and trailing edges of the surface.
        static let inset: CGFloat = 10
        /// How far down the bar may be pushed, as a fraction of the surface.
        /// Only reachable by a match that wraps across many rows; see
        /// `SearchNudge.offset`.
        static let dodgeLimit: CGFloat = 0.45

        static func height(rowHeight: CGFloat) -> CGFloat {
            (max(1, rowHeight) * rowsTall).rounded()
        }
        static func width(rowHeight: CGFloat) -> CGFloat {
            (height(rowHeight: rowHeight) * aspect).rounded()
        }
        /// Rounded corners scale with the panel, or a tall bar looks boxy and a
        /// short one looks like a pill.
        static func cornerRadius(rowHeight: CGFloat) -> CGFloat {
            (height(rowHeight: rowHeight) * 0.27).rounded()
        }
        static func button(rowHeight: CGFloat) -> CGFloat {
            (height(rowHeight: rowHeight) * 0.63).rounded()
        }
        static func font(rowHeight: CGFloat) -> CGFloat {
            (height(rowHeight: rowHeight) * 0.34).rounded()
        }
    }

    /// The terminal's row height, which everything above is measured in.
    private var rowHeight: CGFloat {
        session.rowHeight ?? Metrics.assumedRowHeight
    }

    /// Where the bar sits before anything is dodged.
    private var home: CGRect {
        let width = Metrics.width(rowHeight: rowHeight)
        return CGRect(
            x: max(Metrics.inset, surface.width - width - Metrics.inset),
            y: Metrics.inset,
            width: min(width, max(0, surface.width - 2 * Metrics.inset)),
            height: Metrics.height(rowHeight: rowHeight))
    }

    /// How far down the selected match is pushing it.
    private var dodge: CGFloat {
        SearchNudge.offset(
            bar: home,
            match: session.selectedMatchRect,
            limit: max(home.maxY, surface.height * Metrics.dodgeLimit))
    }

    var body: some View {
        bar
            .offset(x: home.minX, y: home.minY + dodge)
            // Only the dodge animates. The bar's arrival is a transition on the
            // container in `TerminalPane`, and animating the offset itself
            // would make ⌘F slide the bar in from the corner as well.
            .animation(Motion.searchDodge.animation(reduceMotion: reduceMotion), value: dodge)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onEscape { dismiss() }
    }

    private var bar: some View {
        HStack(spacing: 0) {
            TextField("Find", text: Binding(get: { session.query }, set: { session.query = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: Metrics.font(rowHeight: rowHeight), weight: .medium))
                .foregroundStyle(Palette.textBright)
                .focused($fieldFocused)
                .onSubmit { session.selectNext() }
                .onAppear { fieldFocused = true }
                // ⌘F with the bar already up, after a click moved the keyboard
                // into the terminal underneath it.
                .onChange(of: session.focusRequests) { fieldFocused = true }

            Text(count)
                .font(.system(size: Metrics.font(rowHeight: rowHeight) - 1).monospacedDigit())
                .foregroundStyle(
                    session.total == 0 && !session.query.isEmpty
                        ? Palette.textFaint : Palette.textBright
                )
                .lineLimit(1)
                .accessibilityLabel(Text(countLabel))
                .padding(.trailing, 10)

            Rectangle()
                .fill(Palette.searchBarDivider)
                .frame(width: 1, height: (home.height * 0.44).rounded())

            // The chords are the Edit menu's, out of the command table. The
            // words are this bar's: "Next Match" rather than the menu's "Find
            // Next", because a bar with the query still in it is past the point
            // of saying "find".
            step(
                icon: "chevron.up",
                help: Commands.help(.findPrevious, titled: "Previous Match"),
                action: session.selectPrevious)
            step(
                icon: "chevron.down", help: Commands.help(.findNext, titled: "Next Match"),
                action: session.selectNext)
            // Not out of the table: Esc is not a chord any menu item claims —
            // it is `onEscape`'s local monitor, alive only while this bar is.
            step(icon: "xmark", help: "Close (esc)", action: dismiss)
        }
        .padding(.leading, (home.height * 0.34).rounded())
        .padding(.trailing, (home.height * 0.15).rounded())
        // Inside the fill, not around it. A `.frame` applied *outside* the
        // `.background` leaves the stack at its content height and paints the
        // panel at that size, centred in a taller box — which is exactly how
        // this shipped 32 pt tall and drew 22.
        .frame(width: home.width, height: home.height)
        .background(
            RoundedRectangle(
                cornerRadius: Metrics.cornerRadius(rowHeight: rowHeight), style: .continuous
            )
            .fill(Palette.searchBar)
        )
    }

    /// One of the three buttons on the right. `xmark` is one of them rather
    /// than a special case: in the reference they are one evenly spaced group.
    private func step(icon: String, help: String, action: @escaping () -> Void) -> some View {
        let enabled = icon == "xmark" || session.canStep
        let size = Metrics.button(rowHeight: rowHeight)
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: (size * 0.42).rounded(), weight: .semibold))
                .foregroundStyle(enabled ? Palette.textDim : Palette.textFaint)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// "3/12" while there is somewhere to be, "0" when the query found nothing,
    /// and nothing at all before anything has been typed.
    private var count: String {
        guard !session.query.isEmpty else { return "" }
        guard session.total > 0 else { return session.isSearching ? "…" : "0" }
        guard let position = session.position else { return "\(session.total)" }
        return "\(position)/\(session.total)"
    }

    private var countLabel: String {
        guard !session.query.isEmpty else { return "No search" }
        guard session.total > 0 else { return session.isSearching ? "Searching" : "No matches" }
        guard let position = session.position else { return "\(session.total) matches" }
        return "Match \(position) of \(session.total)"
    }

    /// Close, and hand the keyboard back to the terminal.
    ///
    /// The second half is not optional: the field held first responder while
    /// the bar was up, and nothing in the split tree changes when an overlay
    /// goes away, so without this the next keystroke would go nowhere. The
    /// session menu learned the same lesson (W15).
    private func dismiss() {
        session.close()
        store.focusTerminal()
    }
}
