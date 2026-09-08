//  ColorParityTests.swift
//  Our colour parser against the one that wrote the themes.
//
//  `ConfigColor.parse` is a port of libghostty's `RGB.parse`, and this is the
//  test that makes "port" mean something. libghostty is linked here — it is
//  not, in the package where the parser lives — so every input can be handed
//  to `ghostty_color_parse` and the two answers compared. A theme is a config
//  file somebody else wrote against that function; agreeing with it in the
//  cases we thought of is not the same as agreeing with it.
//
//  The X11 table is walked entry by entry from libghostty's own copy, which
//  also checks the fixed-column read of `rgb.txt`: a name our parser dropped
//  or truncated shows up here as a name libghostty knows and we do not.

import GhosttyVt
import XCTest

@testable import IllogicalConfig

final class ColorParityTests: XCTestCase {
    /// What libghostty makes of `input`, or nil.
    private func ghostty(_ input: String) -> ConfigColor? {
        var out = GhosttyColorRgb()
        // `withCString` rather than a buffer over `utf8`: an empty string has
        // no base address, and "" is one of the inputs under test.
        let result = input.withCString { ghostty_color_parse($0, input.utf8.count, &out) }
        guard result == GHOSTTY_SUCCESS else { return nil }
        return ConfigColor(r: out.r, g: out.g, b: out.b)
    }

    private func assertAgrees(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            ConfigColor.parse(input), ghostty(input),
            "disagreed about \"\(input)\"", file: file, line: line)
    }

    // MARK: - The X11 table

    /// Every name libghostty has, read out of libghostty rather than out of
    /// our own copy — so a name missing from ours fails rather than being
    /// quietly not asked about.
    func testEveryX11NameAgrees() {
        var count = 0
        var entry = ghostty_color_x11_names()!
        while let name = entry.pointee.name {
            let text = String(cString: name)
            XCTAssertEqual(
                ConfigColor.parse(text),
                ConfigColor(
                    r: entry.pointee.color.r, g: entry.pointee.color.g,
                    b: entry.pointee.color.b),
                "disagreed about the X11 name \"\(text)\"")
            count += 1
            entry = entry.advanced(by: 1)
        }
        XCTAssertEqual(count, ghostty_color_x11_name_count())
        // A table that silently came back empty would pass every assertion
        // above without checking anything.
        XCTAssertGreaterThan(count, 700)
    }

    func testX11NamesAgreeInEveryCase() {
        for name in ["AliceBlue", "alice blue", "MEDIUM SPRING GREEN", "rebeccapurple"] {
            assertAgrees(name)
            assertAgrees(name.uppercased())
            assertAgrees(name.lowercased())
        }
    }

    // MARK: - Hex

    /// Every 4-bit triple, and every 8-bit channel value, which together cover
    /// the scaling arithmetic exhaustively at the two widths a config file
    /// actually uses.
    func testEveryShortHexAgrees() {
        for r in 0..<16 {
            for g in 0..<16 {
                for b in 0..<16 {
                    assertAgrees(String(format: "#%x%x%x", r, g, b))
                }
            }
        }
    }

    func testEveryByteChannelAgrees() {
        for value in 0..<256 {
            assertAgrees(String(format: "#%02x0000", value))
            assertAgrees(String(format: "%02X%02X%02X", value, value, value))
        }
    }

    /// The 12- and 16-bit forms, where the division rounds and a shift would
    /// not. Stepped rather than exhaustive: 2^16 inputs would agree for the
    /// same reason 2^8 of them do.
    func testWideHexAgrees() {
        for value in stride(from: 0, through: 0xfff, by: 7) {
            assertAgrees(String(format: "#%03x%03x%03x", value, value, value))
        }
        for value in stride(from: 0, through: 0xffff, by: 97) {
            assertAgrees(String(format: "#%04x%04x%04x", value, value, value))
        }
    }

    // MARK: - XParseColor

    func testXParseColorAgrees() {
        for input in [
            "rgb:0/0/0", "rgb:f/f/f", "rgb:1/22/333", "rgb:12/34/56",
            "rgb:1234/5678/9abc", "rgb:ffff/0000/ffff", "rgb:A/B/C",
        ] {
            assertAgrees(input)
        }
    }

    func testIntensityAgrees() {
        for input in [
            "rgbi:0/0/0", "rgbi:1/1/1", "rgbi:0.5/0.5/0.5", "rgbi:.25/.5/.75",
            "rgbi:1./0./0.", "rgbi:0.333333333333333333/0/0", "rgbi:-0/+1/0.0",
            "rgbi:0.1/0.2/0.3",
        ] {
            assertAgrees(input)
        }
    }

    // MARK: - What is not a colour

    /// The interesting half. Swift's `Int(_:radix:)` and `Double(_:)` are both
    /// more permissive than the Zig parsers libghostty uses, so most of these
    /// are inputs a naive port would accept and libghostty rejects.
    func testRejectionsAgree() {
        for input in [
            "", " ", "\t", "#", "#1", "#12", "#1234", "#12345", "#1234567",
            "1234", "1234567", "#gggggg", "notacolour", "  ", "#-12345",
            "#+12345", "rgb", "rgb:", "rgb:1", "rgb:1/2", "rgb:1/2/3/4",
            "rgb:1//2", "rgb://", "rgb:12345/1/1", "rgbi:2/0/0", "rgbi:-1/0/0",
            "rgbi:1e-1/0/0", "rgbi:0x1p0/0/0", "rgbi:inf/0/0", "rgbi:nan/0/0",
            "rgbi:/0/0", "RGB:1/2/3", "rgb 1/2/3", "#٧٧٧", "٧٧٧٧٧٧",
            "rgbi:٠.٥/0/0", "rgb:٧/٧/٧", "#ffffff ", " #ffffff",
        ] {
            assertAgrees(input)
        }
    }

    // MARK: - Palette entries

    private func ghosttyEntry(_ input: String) -> (index: UInt8, color: ConfigColor)? {
        var index: UInt8 = 0
        var out = GhosttyColorRgb()
        let result = input.withCString {
            ghostty_color_parse_palette_entry($0, input.utf8.count, &index, &out)
        }
        guard result == GHOSTTY_SUCCESS else { return nil }
        return (index, ConfigColor(r: out.r, g: out.g, b: out.b))
    }

    func testPaletteEntriesAgree() {
        var inputs = [
            "0=#AABBCC", "0b1=#014589", "0o7=#234567", "0xF=#ABCDEF",
            "0 =  #AABBCC", " 1= #DDEEFF    ", "255=black", "256=#000000",
            "-1=#000000", "0x100=#000000", "=#000000", "0=", "0", "#000000",
            "0=notacolour", "0b2=#000000", "0o8=#000000",
        ]
        // Every index, in the form every theme file writes.
        inputs.append(contentsOf: (0...255).map { "\($0)=#1e1e2e" })

        for input in inputs {
            let ours = ConfigPalette.parseEntry(input)
            let theirs = ghosttyEntry(input)
            XCTAssertEqual(ours?.index, theirs?.index, "index for \"\(input)\"")
            XCTAssertEqual(ours?.color, theirs?.color, "colour for \"\(input)\"")
        }
    }

    // MARK: - The themes the app will ship

    /// Every colour value in a handful of real theme files, which is the only
    /// corpus that matters: these are the strings the parser exists to read.
    func testThemeValuesAgree() {
        let themes = [
            """
            palette = 0=#45475a
            background = #1e1e2e
            foreground = #cdd6f4
            cursor-color = #f5e0dc
            selection-background = #f5e0dc
            """,
            """
            palette = 0=#000000
            palette = 8=#767676
            background = #000000
            foreground = #b3b3b3
            cursor-text = #FFFFFF
            selection-foreground = #000000
            """,
        ]
        for theme in themes {
            for entry in ConfigSyntax.entries(of: theme) {
                guard let value = entry.value else { continue }
                if entry.key == "palette" {
                    let after = value.firstIndex(of: "=").map { value.index(after: $0) }
                    if let after { assertAgrees(String(value[after...])) }
                } else {
                    assertAgrees(value)
                }
            }
        }
    }
}
