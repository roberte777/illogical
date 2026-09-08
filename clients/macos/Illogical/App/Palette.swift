//  Palette.swift
//  The chrome's colours, derived from the terminal's.
//
//  Every value here began as a pixel read off Mitchell's pre-alpha
//  Superlogical recording at 2160p. They are still those colours — the
//  defaults below reproduce them to within a few units per channel — but they
//  are no longer *written down* as those colours. Each is now a relationship
//  to the terminal's own background and foreground, fitted to the sample it
//  replaces, so that a theme repaints the window rather than the rectangle in
//  the middle of it. A dark blue toolbar around a cream Gruvbox terminal is
//  not a theme; it is a theme and a frame that has not heard about it.
//
//  Three relationships do nearly all of it:
//
//    * `tint(t)` — the background moved t of the way toward the foreground.
//      Structure: dividers, tab fills, strokes, the find bar. Self-inverting,
//      which is the point: on a light theme these become *darker* than the
//      terminal without needing a second rule, because "toward the
//      foreground" is downward when the foreground is dark.
//    * `text(t)` — the foreground moved t of the way toward the background.
//      Type, at three weights.
//    * `shade(t)` — the background moved away from the terminal altogether,
//      toward black. What makes the toolbar read as sitting *outside* the
//      terminal rather than inside it, and the one rule that needs an escape
//      hatch: see `shade`.
//
//  Nothing is left undetermined by the theme, including the green on the tab
//  badge and the blue behind a selected menu row: those come from the theme's
//  own palette now, because a fixed green on a Rosé Pine window is the same
//  mistake as a fixed toolbar.

import IllogicalConfig
import SwiftUI
import os

enum Palette {
    /// What the chrome is derived from.
    ///
    /// The defaults are the terminal's own defaults — the two colours `Config`
    /// starts with, and libghostty's ANSI green and blue — so a process that
    /// never calls `adopt` draws exactly what the app drew before any of this
    /// was configurable. That is every test, and it is the correct answer for
    /// all of them.
    struct Source: Sendable, Equatable {
        var background = ConfigColor(0x0C_1F_2F)
        var foreground = ConfigColor(0xC8_D6_E0)
        /// Palette indices 2 and 4: the tab badge's glyph, and the selected
        /// row in the session menu.
        var green = ConfigColor(0x4E_D8_5F)
        var blue = ConfigColor(0x5C_9D_F9)
    }

    /// Read from SwiftUI bodies on the main actor and from the surface view's
    /// layer setup; written once, before any window exists. The lock is for
    /// the memory model rather than for contention, exactly as `AppConfig`'s
    /// is — and an uncontended `OSAllocatedUnfairLock` is a few nanoseconds,
    /// which is affordable per body evaluation.
    private static let storage = OSAllocatedUnfairLock(initialState: Source())

    static var source: Source { storage.withLock { $0 } }

    /// Take the colours a config resolved to. Called once, from
    /// `AppConfig.load()`.
    static func adopt(_ source: Source) { storage.withLock { $0 = source } }

    // MARK: - Mixing

    static func rgb(_ hex: UInt32) -> Color { color(ConfigColor(hex)) }

    static func color(_ c: ConfigColor) -> Color {
        Color(
            .sRGB,
            red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    /// `a` moved `t` of the way toward `b`, in sRGB.
    ///
    /// sRGB and not a linear or perceptual space, because these values were
    /// chosen by eye against sRGB numbers: mixing where the designer mixed is
    /// what makes the fitted constants reproduce the samples. The one place a
    /// perceptual answer is actually wanted — "is this background light?" — is
    /// libghostty's to answer, and does not arise here.
    static func mix(_ a: ConfigColor, _ b: ConfigColor, _ t: Double) -> ConfigColor {
        func channel(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8(max(0, min(255, (Double(x) + (Double(y) - Double(x)) * t).rounded())))
        }
        return ConfigColor(r: channel(a.r, b.r), g: channel(a.g, b.g), b: channel(a.b, b.b))
    }

    /// The background, `t` of the way toward the foreground. Structure.
    static func tint(_ t: Double) -> Color {
        let source = source
        return color(mix(source.background, source.foreground, t))
    }

    /// The foreground, `t` of the way toward the background. Type.
    static func text(_ t: Double) -> Color {
        let source = source
        return color(mix(source.foreground, source.background, t))
    }

    /// The background, `t` of the way toward black: further from the terminal
    /// than the terminal is from anything.
    ///
    /// Toward black in both directions, which is not a slip. On a dark theme
    /// it darkens the chrome; on a light one it darkens it too — which is what
    /// macOS does, and what makes a toolbar read as chrome rather than as more
    /// terminal.
    ///
    /// The escape hatch is for a background that is already black, which a
    /// great many themes are: there is nothing left to take away, so the
    /// chrome would be exactly the terminal and the window would have no
    /// edges at all. Below a threshold of separation it goes the other way
    /// instead, and by less, because a *lighter* toolbar is a compromise and
    /// should look like one.
    static func shade(_ t: Double) -> Color {
        let source = source
        let darker = mix(source.background, ConfigColor(0), t)
        guard contrast(darker, source.background) < 1.04 else { return color(darker) }
        return color(mix(source.background, source.foreground, t * 0.6))
    }

    /// WCAG contrast, 1 through 21. libghostty's `ghostty_color_contrast`
    /// computes the same thing, and is not reached for here only because this
    /// file is on the SwiftUI side of the app and imports no C.
    static func contrast(_ a: ConfigColor, _ b: ConfigColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// W3C relative luminance.
    static func luminance(_ c: ConfigColor) -> Double {
        func channel(_ v: UInt8) -> Double {
            let v = Double(v) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    /// Whichever of the two reads better on `background`.
    ///
    /// For the one place a colour lands on something that is neither the
    /// terminal's background nor a shade of it: the text on a selected menu
    /// row, which sits on the theme's blue. Picking by contrast is what keeps
    /// it legible whether that blue came out near-black or near-white.
    static func readable(on background: ConfigColor) -> Color {
        let source = source
        return contrast(source.background, background) >= contrast(source.foreground, background)
            ? color(source.background) : color(source.foreground)
    }

    // MARK: - The window

    /// The terminal's own ground, which the surface draws too.
    static var background: Color { color(source.background) }
    /// The toolbar, outside the terminal and darker than it.
    static var toolbar: Color { shade(0.17) }
    /// The hairline under the toolbar.
    static var divider: Color { tint(0.08) }

    // MARK: - Tabs

    /// Active tab pill.
    static var tabActiveFill: Color { tint(0.07) }
    static var tabActiveStroke: Color { tint(0.19) }
    /// The foreground rather than white, so that hovering a tab on a light
    /// theme darkens it instead of washing it out.
    static var tabHoverFill: Color { color(source.foreground).opacity(0.04) }
    /// The hairline between inactive tabs.
    static var tabSeparator: Color { tint(0.18) }

    // MARK: - Type

    static var textBright: Color { text(0.02) }
    static var textDim: Color { text(0.37) }
    static var textFaint: Color { text(0.55) }

    // MARK: - The find bar

    /// The find bar, floating over a terminal.
    ///
    /// The reference recording has a flat `#212121` panel over a `#0F0F0F`
    /// terminal: neutral, borderless, and *lighter* than what it covers, which
    /// is what makes it read as floating over the screen rather than cut into
    /// it. It is the opposite of the toolbar, which is darker than the
    /// terminal because it sits outside it.
    ///
    /// Expressed as a step toward the foreground rather than as a fixed lift,
    /// that relationship survives a light theme: over a cream terminal the
    /// same rule produces a panel that is darker, which is what "distinct from
    /// what it covers" means there.
    static var searchBar: Color { tint(0.18) }
    /// The hairline between the match count and the step buttons.
    static var searchBarDivider: Color { color(source.foreground).opacity(0.13) }

    // MARK: - The tab badge

    /// The Terminal.app-style badge on each tab, and the glyph in it — the
    /// theme's own green rather than a fixed one.
    static var badgeFill: Color { tint(0.17) }
    static var badgeStroke: Color { shade(0.30) }
    static var badgeGlyph: Color { color(source.green) }
}
