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

    enum Metrics {
        static let width: CGFloat = 300
        static let height: CGFloat = 32
        /// From the top and trailing edges of the surface.
        static let inset: CGFloat = 10
        static let cornerRadius: CGFloat = 10
        static let button: CGFloat = 22
        /// How far down the bar may be pushed, as a fraction of the surface.
        /// Only reachable by a match that wraps across many rows; see
        /// `SearchNudge.offset`.
        static let dodgeLimit: CGFloat = 0.45
    }

    /// Where the bar sits before anything is dodged.
    private var home: CGRect {
        CGRect(
            x: max(Metrics.inset, surface.width - Metrics.width - Metrics.inset),
            y: Metrics.inset,
            width: min(Metrics.width, max(0, surface.width - 2 * Metrics.inset)),
            height: Metrics.height)
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
            .frame(width: home.width, height: home.height)
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textBright)
                .focused($fieldFocused)
                .onSubmit { session.selectNext() }
                .onAppear { fieldFocused = true }
                // ⌘F with the bar already up, after a click moved the keyboard
                // into the terminal underneath it.
                .onChange(of: session.focusRequests) { fieldFocused = true }

            Text(count)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(
                    session.total == 0 && !session.query.isEmpty
                        ? Palette.textFaint : Palette.textBright
                )
                .lineLimit(1)
                .accessibilityLabel(Text(countLabel))
                .padding(.trailing, 10)

            Rectangle()
                .fill(Palette.searchBarDivider)
                .frame(width: 1, height: Metrics.height - 14)

            step(icon: "chevron.up", help: "Previous Match (⇧⌘G)", action: session.selectPrevious)
            step(icon: "chevron.down", help: "Next Match (⌘G)", action: session.selectNext)
            step(icon: "xmark", help: "Close (esc)", action: dismiss)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Palette.searchBar)
        )
    }

    /// One of the three buttons on the right. `xmark` is one of them rather
    /// than a special case: in the reference they are one evenly spaced group.
    private func step(icon: String, help: String, action: @escaping () -> Void) -> some View {
        let enabled = icon == "xmark" || session.canStep
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? Palette.textDim : Palette.textFaint)
                .frame(width: Metrics.button, height: Metrics.button)
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
