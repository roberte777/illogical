//  SearchBar.swift
//  The find bar, floating over the terminal it is searching.
//
//      ┌──────────────────────────────────────────────┐
//      │ ⌕  open                    1/2   ∧  ∨    ✕   │
//      └──────────────────────────────────────────────┘
//
//  Over the surface rather than above it, and that is the whole design: a bar
//  that pushed the grid down would resize the PTY — a `winsize` change, an
//  ANSI resize to every program in the terminal, and a reflow of the screen
//  you are searching — every time ⌘F is pressed. Floating costs nothing and
//  reflows nothing.
//
//  The price of floating is that the bar covers something, and the one thing
//  it must not cover is a match. So it dodges: `SearchNudge` says how far down
//  it has to go to be clear of everything the search found, and the move is
//  animated because a bar that teleports as you type reads as a glitch rather
//  than as a bar getting out of the way.

import SwiftUI

struct SearchBar: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: SearchSession
    /// The surface's own size, which is the space `session.matchRects` are in.
    let surface: CGSize

    @FocusState private var fieldFocused: Bool

    enum Metrics {
        static let width: CGFloat = 296
        static let height: CGFloat = 30
        /// From the top and trailing edges of the surface.
        static let inset: CGFloat = 10
        static let cornerRadius: CGFloat = 8
        /// How far down the bar may be pushed, as a fraction of the surface.
        /// Past this the top of the screen is hopelessly busy and a find bar in
        /// the middle of it is worse than one covering a hit.
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

    /// How far down the matches are pushing it.
    private var dodge: CGFloat {
        SearchNudge.offset(
            bar: home,
            matches: session.matchRects,
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textDim)

            TextField("Find", text: Binding(get: { session.query }, set: { session.query = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textBright)
                .focused($fieldFocused)
                .onSubmit { session.selectNext() }
                .onAppear { fieldFocused = true }
                // ⌘F with the bar already up, after a click moved the keyboard
                // into the terminal underneath it.
                .onChange(of: session.focusRequests) { fieldFocused = true }

            Text(count)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(
                    session.total == 0 && !session.query.isEmpty
                        ? Palette.textFaint : Palette.textDim
                )
                .lineLimit(1)
                .accessibilityLabel(Text(countLabel))

            step(icon: "chevron.up", help: "Previous Match (⇧⌘G)", action: session.selectPrevious)
            step(icon: "chevron.down", help: "Next Match (⌘G)", action: session.selectNext)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.textDim)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (esc)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Palette.toolbar)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.divider, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        )
    }

    private func step(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(session.canStep ? Palette.textDim : Palette.textFaint)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.canStep)
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
