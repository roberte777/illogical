//  FontConfig.swift
//  Which fonts a grid is built from, and at what size.
//
//  A list per style rather than one family name, because that is what
//  `font-family` repeating means: each entry is the next place to look for a
//  codepoint the one before it does not have. libghostty's `Collection` has
//  the same shape and for the same reason.
//
//  Four lists rather than one plus modifiers, because a style is never
//  borrowed across families. If the bold list is empty, bold comes from the
//  *regular* family — its own bold face, or a synthesized one — and never from
//  the next family down. Bold text drawn in a different typeface than the text
//  around it is the failure that arrangement exists to prevent, and by the
//  time the grid is built the distinction is gone, so it has to be carried
//  here.
//
//  No dependency on the config package: this is what the renderer needs, and
//  `AppConfig.font` is what turns a config file into it. The renderer is
//  testable without a config file, and there is exactly one place that knows
//  how the two vocabularies line up.

import Foundation

struct FontConfig: Hashable, Sendable {
    /// Families for each style, in priority order. Empty means the font the
    /// app ships, which is the case for anyone who has not written a config
    /// file.
    var regular: [String] = []
    var bold: [String] = []
    var italic: [String] = []
    var boldItalic: [String] = []

    /// Points, not pixels. The grid multiplies by the display scale.
    var pointSize: Double = 13

    subscript(style: FontStyle) -> [String] {
        switch style {
        case .regular: regular
        case .bold: bold
        case .italic: italic
        case .boldItalic: boldItalic
        }
    }
}

extension FontConfig {
    /// One family for every style, or none at all.
    ///
    /// What almost every test wants, and what a single `font-family` line
    /// amounts to once `Config.finalize` has copied it across the styles.
    init(family: String?, pointSize: Double = 13) {
        let families = family.map { [$0] } ?? []
        self.init(
            regular: families, bold: families, italic: families, boldItalic: families,
            pointSize: pointSize)
    }
}
