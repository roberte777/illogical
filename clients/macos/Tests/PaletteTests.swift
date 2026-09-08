//  PaletteTests.swift
//  The chrome's colours, against the samples they replaced.
//
//  The first test is the one that matters: with no theme, every derived
//  colour has to come out where the sampled constant was. The relationships
//  in `Palette` were fitted to those samples, so this is what says the fit
//  still holds — and what would fail if somebody adjusted a constant to make
//  one theme look better and repainted the default window doing it.
//
//  A tolerance of 6 per channel, which is the fit's own error. It is a long
//  way below what anybody can see on two colours that are not adjacent, and
//  the samples were themselves read off a video at 2160p.

import SwiftUI
import XCTest

@testable import IllogicalConfig

final class PaletteTests: XCTestCase {
    override func tearDown() {
        Palette.adopt(Palette.Source())
        super.tearDown()
    }

    /// The sRGB bytes behind a `Color`, back out of SwiftUI.
    private func bytes(_ color: Color) -> (r: Int, g: Int, b: Int) {
        let cg = NSColor(color).usingColorSpace(.sRGB)!
        return (
            Int((cg.redComponent * 255).rounded()),
            Int((cg.greenComponent * 255).rounded()),
            Int((cg.blueComponent * 255).rounded())
        )
    }

    private func assertNear(
        _ color: Color, _ hex: UInt32, tolerance: Int = 6,
        _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = bytes(color)
        let expected = (
            r: Int((hex >> 16) & 0xff), g: Int((hex >> 8) & 0xff), b: Int(hex & 0xff)
        )
        let delta = max(
            abs(actual.r - expected.r), abs(actual.g - expected.g), abs(actual.b - expected.b))
        XCTAssertLessThanOrEqual(
            delta, tolerance,
            "\(label): rgb(\(actual.r), \(actual.g), \(actual.b)) is \(delta) from "
                + String(format: "#%06x", hex),
            file: file, line: line)
    }

    /// Every value that used to be written down, where it used to be.
    func testDefaultsReproduceTheSampledPalette() {
        assertNear(Palette.background, 0x0C_1F_2F, tolerance: 0, "background")
        assertNear(Palette.divider, 0x1D_2D_3E, "divider")
        assertNear(Palette.tabActiveFill, 0x17_2A_3F, "tabActiveFill")
        assertNear(Palette.tabActiveStroke, 0x2A_43_55, tolerance: 8, "tabActiveStroke")
        assertNear(Palette.tabSeparator, 0x2A_3F_52, "tabSeparator")
        assertNear(Palette.textBright, 0xC3_D3_DE, "textBright")
        assertNear(Palette.textDim, 0x7E_93_A4, "textDim")
        assertNear(Palette.textFaint, 0x5E_72_82, "textFaint")
        assertNear(Palette.searchBar, 0x33_40_4C, tolerance: 12, "searchBar")
        assertNear(Palette.badgeGlyph, 0x4E_D8_5F, tolerance: 0, "badgeGlyph")
        assertNear(Palette.menuHighlight, 0x5C_9D_F9, tolerance: 0, "menuHighlight")
        assertNear(Palette.menuText, 0xD3_DB_DE, tolerance: 12, "menuText")
        assertNear(Palette.menuShortcut, 0x7E_93_A4, "menuShortcut")
        // The toolbar is the loosest fit of the lot, and knowingly: the
        // sample is not a darkening of the background at all but a hue shift
        // toward blue, which no scalar relationship reproduces. What is kept
        // is that it is darker, and by about as much.
        assertNear(Palette.toolbar, 0x06_1D_31, tolerance: 12, "toolbar")
    }

    // MARK: - Following a theme

    private func adopt(background: UInt32, foreground: UInt32) {
        Palette.adopt(
            Palette.Source(
                background: ConfigColor(background), foreground: ConfigColor(foreground)))
    }

    /// The whole point: change the terminal's two colours and the window
    /// moves with them.
    func testChromeFollowsTheTerminal() {
        adopt(background: 0x1E_1E_2E, foreground: 0xCD_D6_F4)
        assertNear(Palette.background, 0x1E_1E_2E, tolerance: 0, "background")
        // Structure sits between the two, so it is lighter than a dark ground.
        XCTAssertGreaterThan(
            Palette.luminance(ConfigColor(0x1E_1E_2E)), 0,
            "the fixture is not black, which the next assertions assume")
        for color in [Palette.divider, Palette.tabActiveFill, Palette.searchBar] {
            let c = bytes(color)
            XCTAssertGreaterThan(c.r + c.g + c.b, 0x1E + 0x1E + 0x2E)
        }
    }

    /// A light theme has to invert every one of those relationships, and the
    /// rules are written so that it does without a second code path.
    func testALightThemeInvertsTheStructure() {
        adopt(background: 0xFB_F1_C7, foreground: 0x3C_38_36)
        // Structure is now *darker* than the terminal, because "toward the
        // foreground" is downward here.
        for (name, color) in [
            ("divider", Palette.divider), ("tabActiveFill", Palette.tabActiveFill),
            ("tabSeparator", Palette.tabSeparator), ("searchBar", Palette.searchBar),
            ("badgeFill", Palette.badgeFill),
        ] {
            let c = bytes(color)
            XCTAssertLessThan(
                c.r + c.g + c.b, 0xFB + 0xF1 + 0xC7, "\(name) did not darken on a light theme")
        }
        // And the toolbar, which darkens on any theme, still does.
        let toolbar = bytes(Palette.toolbar)
        XCTAssertLessThan(toolbar.r + toolbar.g + toolbar.b, 0xFB + 0xF1 + 0xC7)
        // Type is dark on light, and the three weights stay ordered.
        XCTAssertLessThan(bytes(Palette.textBright).r, 0x60)
        XCTAssertLessThan(bytes(Palette.textBright).r, bytes(Palette.textDim).r)
        XCTAssertLessThan(bytes(Palette.textDim).r, bytes(Palette.textFaint).r)
    }

    /// The escape hatch. A great many themes are black, and black cannot be
    /// darkened: the toolbar would be the terminal and the window would have
    /// no edges.
    func testAPureBlackThemeGetsALighterToolbarRatherThanNone() {
        adopt(background: 0x00_00_00, foreground: 0xFF_FF_FF)
        let toolbar = bytes(Palette.toolbar)
        XCTAssertGreaterThan(toolbar.r + toolbar.g + toolbar.b, 0, "the toolbar vanished")
        XCTAssertLessThan(toolbar.r, 60, "the compromise should be slight")
        // The same rule keeps the badge's outline visible.
        XCTAssertGreaterThan(bytes(Palette.badgeStroke).r, 0)
    }

    /// Text on the selected menu row is picked by contrast, so a theme whose
    /// blue is pale does not end up with pale text on it.
    func testMenuHighlightTextIsPickedByContrast() {
        // A dark blue on a dark theme: the light foreground reads.
        Palette.adopt(
            Palette.Source(
                background: ConfigColor(0x1E_1E_2E), foreground: ConfigColor(0xCD_D6_F4),
                blue: ConfigColor(0x1A_2A_6E)))
        XCTAssertGreaterThan(bytes(Palette.menuHighlightText).r, 0x80)

        // A pale blue on the same theme: the dark background reads.
        Palette.adopt(
            Palette.Source(
                background: ConfigColor(0x1E_1E_2E), foreground: ConfigColor(0xCD_D6_F4),
                blue: ConfigColor(0xBF_D7_FF)))
        XCTAssertLessThan(bytes(Palette.menuHighlightText).r, 0x80)
    }
}
