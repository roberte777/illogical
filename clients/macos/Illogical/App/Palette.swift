//  Palette.swift
//  The colours, sampled rather than guessed.
//
//  Every value here was read off a pixel in Mitchell's pre-alpha Superlogical
//  recording at 2160p. Its own file rather than living in `Chrome.swift`,
//  because the terminal surface needs the background colour too and pulling
//  the whole chrome in behind it is more than that is worth.

import SwiftUI

enum Palette {
    static func rgb(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }

    /// Sampled from empty toolbar, right of the last tab.
    static let toolbar = rgb(0x06_1D_31)
    /// Sampled from empty terminal background.
    static let background = rgb(0x0C_1F_2F)
    /// The hairline under the toolbar.
    static let divider = rgb(0x1D_2D_3E)

    /// Active tab pill.
    static let tabActiveFill = rgb(0x17_2A_3F)
    static let tabActiveStroke = rgb(0x2A_43_55)
    static let tabHoverFill = Color.white.opacity(0.04)
    /// The hairline between inactive tabs.
    static let tabSeparator = rgb(0x2A_3F_52)

    static let textBright = rgb(0xC3_D3_DE)
    static let textDim = rgb(0x7E_93_A4)
    static let textFaint = rgb(0x5E_72_82)

    /// The find bar, floating over a terminal.
    ///
    /// Sampled the way everything else here was, from the find bar in the
    /// reference recording: a flat `#212121` panel over a `#0F0F0F` terminal.
    /// Neutral, borderless, and *lighter* than what it covers — which is what
    /// makes it read as floating over the screen rather than cut into it, and
    /// is the opposite of the toolbar, which is darker than the terminal
    /// because it sits outside it.
    ///
    /// Our ground is the blue `background` rather than near-black, so what
    /// carries across is the *ratio* rather than the grey: `#212121` on
    /// `#0F0F0F` is a 2.2× lift in relative luminance, and this is the colour
    /// that lifts `#0C1F2F` by the same 2.2×. Measured off a screenshot of
    /// each rather than eyeballed — the first attempt matched the absolute
    /// step instead, which on a lighter ground came out at 1.66× and read as
    /// barely there.
    static let searchBar = rgb(0x33_40_4C)
    /// The hairline between the match count and the step buttons.
    static let searchBarDivider = Color.white.opacity(0.13)

    /// The Terminal.app-style badge on each tab.
    static let badgeFill = rgb(0x3A_3D_42)
    static let badgeStroke = rgb(0x17_19_1C)
    static let badgeGlyph = rgb(0x4E_D8_5F)
}
