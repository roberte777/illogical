//  TerminalColorsTests.swift
//  The palette a config adds up to, and the colours the terminal is told.
//
//  The interesting half is `palette-generate`, which is the one part of a
//  theme this app does not compute: it hands the base colours to libghostty
//  and gets Ghostty's own CIELAB interpolation back. So the tests are about
//  the wiring — that overrides survive generation, that a config which
//  overrode nothing is left alone, that the mask reaches indices above 15 —
//  rather than about the numbers, which are libghostty's to be right about.

import GhosttyVt
import XCTest

@testable import IllogicalConfig

final class TerminalColorsTests: XCTestCase {
    private func config(_ text: String) -> Config {
        var config = Config()
        var diagnostics: [ConfigDiagnostic] = []
        config.apply(text: text, path: "config", diagnostics: &diagnostics)
        config.finalize()
        XCTAssertEqual(diagnostics.map(\.description), [], "the config under test has warnings")
        return config
    }

    /// libghostty's own default palette, for comparing against.
    private var defaultPalette: [GhosttyColorRgb] {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        palette.withUnsafeMutableBufferPointer { ghostty_color_palette_default($0.baseAddress) }
        return palette
    }

    private func assertEqual(
        _ a: GhosttyColorRgb, _ b: GhosttyColorRgb,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual([a.r, a.g, a.b], [b.r, b.g, b.b], message(), file: file, line: line)
    }

    // MARK: - The three single colours

    func testDefaultsAreTheAppsOwn() {
        let colors = TerminalColors.from(Config())
        assertEqual(colors.background, GhosttyColorRgb(r: 0x0C, g: 0x1F, b: 0x2F))
        assertEqual(colors.foreground, GhosttyColorRgb(r: 0xC8, g: 0xD6, b: 0xE0))
        XCTAssertNil(colors.cursor)
    }

    func testBackgroundAndForegroundComeFromTheConfig() {
        let colors = TerminalColors.from(
            config(
                """
                background = #1e1e2e
                foreground = #cdd6f4
                """))
        assertEqual(colors.background, GhosttyColorRgb(r: 0x1E, g: 0x1E, b: 0x2E))
        assertEqual(colors.foreground, GhosttyColorRgb(r: 0xCD, g: 0xD6, b: 0xF4))
    }

    /// A fixed cursor colour is the terminal's, so that OSC 12 can override it
    /// and OSC 112 can put it back.
    func testAFixedCursorColorGoesToTheTerminal() {
        let colors = TerminalColors.from(config("cursor-color = #f5e0dc"))
        assertEqual(colors.cursor!, GhosttyColorRgb(r: 0xF5, g: 0xE0, b: 0xDC))
    }

    /// A cell-relative one cannot: there is no colour to hand over. It stays
    /// unset so that `snapshot.cursorColor` keeps meaning "a program set this",
    /// and the renderer resolves the config's answer per frame.
    func testACellRelativeCursorColorDoesNot() {
        XCTAssertNil(TerminalColors.from(config("cursor-color = cell-foreground")).cursor)
        XCTAssertNil(TerminalColors.from(config("cursor-color = cell-background")).cursor)
    }

    // MARK: - The palette

    func testAnEmptyConfigIsLibghosttysOwnPalette() {
        let palette = TerminalColors.from(Config()).palette
        XCTAssertEqual(palette.count, 256)
        for (index, color) in palette.enumerated() {
            assertEqual(color, defaultPalette[index], "index \(index)")
        }
    }

    func testOverridesReplaceTheirIndicesAndNothingElse() {
        let palette = TerminalColors.from(
            config(
                """
                palette = 1=#f38ba8
                palette = 200=#ffffff
                """)
        ).palette
        assertEqual(palette[1], GhosttyColorRgb(r: 0xF3, g: 0x8B, b: 0xA8))
        assertEqual(palette[200], GhosttyColorRgb(r: 0xFF, g: 0xFF, b: 0xFF))
        for index in [0, 2, 15, 16, 199, 201, 255] {
            assertEqual(palette[index], defaultPalette[index], "index \(index)")
        }
    }

    /// With nothing overridden there is nothing to derive from, so generation
    /// is skipped and the default palette comes through unchanged.
    func testGenerateWithoutOverridesChangesNothing() {
        let palette = TerminalColors.from(config("palette-generate = true")).palette
        for (index, color) in palette.enumerated() {
            assertEqual(color, defaultPalette[index], "index \(index)")
        }
    }

    /// The point of the option: sixteen base colours, and a cube in keeping
    /// with them rather than xterm's.
    func testGenerateRewritesTheCubeFromTheBaseColors() {
        let text = (0...15).map { "palette = \($0)=#\(String(format: "%02x", $0 * 16))0000" }
            .joined(separator: "\n")
        let generated = TerminalColors.from(
            config(
                """
                \(text)
                background = #000000
                foreground = #ffffff
                palette-generate = true
                """)
        ).palette
        let plain = TerminalColors.from(config(text)).palette

        // The sixteen the config named survive either way.
        for index in 0...15 {
            assertEqual(generated[index], plain[index], "base index \(index)")
        }
        // The cube and the ramp do not: without generation they are xterm's,
        // with it they are derived. If these matched, the option did nothing.
        XCTAssertNotEqual(
            (16...255).map { [generated[$0].r, generated[$0].g, generated[$0].b] },
            (16...255).map { [plain[$0].r, plain[$0].g, plain[$0].b] })
    }

    /// An override above 15 is in the range generation would otherwise cover,
    /// which is exactly what the skip mask is for.
    func testGenerateLeavesAnOverriddenCubeIndexAlone() {
        let base = (0...15).map { "palette = \($0)=#\(String(format: "%02x", $0 * 16))0000" }
            .joined(separator: "\n")
        let palette = TerminalColors.from(
            config(
                """
                \(base)
                palette = 200=#00ff00
                palette-generate = true
                """)
        ).palette
        assertEqual(palette[200], GhosttyColorRgb(r: 0x00, g: 0xFF, b: 0x00))
    }

    func testHarmoniousChangesTheGeneratedCube() {
        let base =
            (0...15).map { "palette = \($0)=#\(String(format: "%02x", $0 * 16))0000" }
            .joined(separator: "\n") + "\nbackground = #ffffff\nforeground = #000000\n"
        let plain = TerminalColors.from(config(base + "palette-generate = true")).palette
        let harmonious = TerminalColors.from(
            config(base + "palette-generate = true\npalette-harmonious = true")
        ).palette
        XCTAssertNotEqual(
            (16...255).map { [plain[$0].r, plain[$0].g, plain[$0].b] },
            (16...255).map { [harmonious[$0].r, harmonious[$0].g, harmonious[$0].b] })
    }
}
