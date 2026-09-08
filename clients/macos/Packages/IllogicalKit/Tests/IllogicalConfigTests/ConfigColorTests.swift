//  ConfigColorTests.swift
//  Every shape a colour can take, and the ones it cannot.
//
//  The cases come from libghostty's own tests for `RGB.parse` and
//  `parsePaletteEntry` (`terminal/color.zig`), plus the handful of inputs
//  where a Swift port could plausibly drift from a Zig one: Unicode digits
//  that `Int(_:radix:)` accepts and `parseInt` does not, a float syntax that
//  `Double(_:)` accepts and XParseColor does not, and the six-letter colour
//  name made entirely of hex digits.
//
//  `ConfigColorParityTests` in the app checks the same parser against
//  `ghostty_color_parse` itself. These are here because this package builds
//  without libghostty, and because a failure with a name on it is a better
//  first thing to read than a table diff.

import Testing

@testable import IllogicalConfig

@Suite("Config colours")
struct ConfigColorTests {
    @Test("hex, with and without the #")
    func hex() {
        #expect(ConfigColor.parse("#000000") == ConfigColor(r: 0, g: 0, b: 0))
        #expect(ConfigColor.parse("#0A0B0C") == ConfigColor(r: 10, g: 11, b: 12))
        #expect(ConfigColor.parse("0A0B0C") == ConfigColor(r: 10, g: 11, b: 12))
        #expect(ConfigColor.parse("FFFFFF") == ConfigColor(r: 255, g: 255, b: 255))
        #expect(ConfigColor.parse("FFF") == ConfigColor(r: 255, g: 255, b: 255))
        #expect(ConfigColor.parse("#345") == ConfigColor(r: 51, g: 68, b: 85))
    }

    @Test("a short channel is scaled by division, not by a shift")
    func hexScaling() {
        // #800 is 8/15 of full, which is 136. Repeating the nibble — the
        // shortcut every "#rgb -> #rrggbb" snippet takes — gives 0x88, the
        // same 136. Shifting left by four would give 128, and that is the
        // answer this test exists to rule out.
        #expect(ConfigColor.parse("#800") == ConfigColor(r: 136, g: 0, b: 0))
        // 12- and 16-bit channels scale down by the same division, which
        // truncates: 0x8000 of 0xffff is 127.49 of 255, and so 127.
        #expect(ConfigColor.parse("#800800800") == ConfigColor(r: 127, g: 127, b: 127))
        #expect(ConfigColor.parse("#800080008000") == ConfigColor(r: 127, g: 127, b: 127))
    }

    @Test("an X11 name, matched without regard to case")
    func names() {
        #expect(ConfigColor.parse("black") == ConfigColor(r: 0, g: 0, b: 0))
        #expect(ConfigColor.parse("ForestGreen") == ConfigColor(r: 34, g: 139, b: 34))
        #expect(ConfigColor.parse("forestgreen") == ConfigColor(r: 34, g: 139, b: 34))
        // The spaced spelling is its own entry in rgb.txt, and it survives the
        // file's fixed-column layout only if the name column is read to the
        // end of the line.
        #expect(ConfigColor.parse("cornflower blue") == ConfigColor(r: 100, g: 149, b: 237))
    }

    @Test("a name that is also six hex digits is the name")
    func nameBeatsHex() {
        // `bisque` is six characters, every one of them a hex digit, and it is
        // also an X11 colour. libghostty looks names up before it reads bare
        // hex, so it is the peach and not #B15C0E — and a port that checked
        // hex first would silently draw a different colour for it.
        #expect(ConfigColor.parse("bisque") == ConfigColor(r: 255, g: 228, b: 196))
        #expect(ConfigColor.parse("BISQUE") == ConfigColor(r: 255, g: 228, b: 196))
        // Six hex digits that are *not* a name still read as hex.
        #expect(ConfigColor.parse("beefed") == ConfigColor(r: 0xBE, g: 0xEF, b: 0xED))
    }

    @Test("rgb: takes one to four hex digits a channel")
    func xParseColor() {
        #expect(ConfigColor.parse("rgb:f/f/f") == ConfigColor(r: 255, g: 255, b: 255))
        #expect(ConfigColor.parse("rgb:12/34/56") == ConfigColor(r: 0x12, g: 0x34, b: 0x56))
        #expect(ConfigColor.parse("rgb:1234/5678/9abc") == ConfigColor(r: 0x12, g: 0x56, b: 0x9a))
    }

    @Test("rgbi: takes decimal fractions")
    func intensity() {
        #expect(ConfigColor.parse("rgbi:1/1/1") == ConfigColor(r: 255, g: 255, b: 255))
        #expect(ConfigColor.parse("rgbi:0/0/0") == ConfigColor(r: 0, g: 0, b: 0))
        #expect(ConfigColor.parse("rgbi:0.5/.5/1.") == ConfigColor(r: 127, g: 127, b: 255))
    }

    @Test("rgbi: is XParseColor's fraction, not Swift's Double")
    func intensityIsRestricted() {
        // Every one of these is a number `Double(_:)` reads happily.
        #expect(ConfigColor.parse("rgbi:1e-1/0/0") == nil)
        #expect(ConfigColor.parse("rgbi:0x1p0/0/0") == nil)
        #expect(ConfigColor.parse("rgbi:inf/0/0") == nil)
        #expect(ConfigColor.parse("rgbi:nan/0/0") == nil)
        // And out of the unit interval, which XParseColor does not allow.
        #expect(ConfigColor.parse("rgbi:1.5/0/0") == nil)
        #expect(ConfigColor.parse("rgbi:-0.5/0/0") == nil)
        // -0 is in range, and is the one negative that passes.
        #expect(ConfigColor.parse("rgbi:-0/0/0") == ConfigColor(r: 0, g: 0, b: 0))
    }

    @Test("leading and trailing spaces and tabs are ignored")
    func whitespace() {
        #expect(ConfigColor.parse(" #AABBCC   ") == ConfigColor(r: 0xAA, g: 0xBB, b: 0xCC))
        #expect(ConfigColor.parse("\t black \t") == ConfigColor(r: 0, g: 0, b: 0))
    }

    @Test("digits that are not ASCII digits are not a colour")
    func unicodeDigits() {
        // `UInt16("٧٧٧", radix: 16)` is 1911. XParseColor has never heard of
        // Arabic-Indic digits, and neither has any config file.
        #expect(ConfigColor.parse("#٧٧٧") == nil)
        #expect(ConfigColor.parse("rgbi:٠.٥/0/0") == nil)
        // A leading sign is the other thing Swift's initialisers take.
        #expect(ConfigColor.parse("#+12345") == nil)
        #expect(ConfigColor.parse("rgb:+1/2/3") == nil)
    }

    @Test("anything else is not a colour")
    func rejected() {
        for input in [
            "", "   ", "#", "#12", "#1234", "12345", "#gggggg", "notacolour",
            "rgb:1/2", "rgb:1/2/3/4", "rgb:1//2", "rgb1/2/3", "RGB:1/2/3", "rgb:", "rgb:12345/1/1",
        ] {
            #expect(ConfigColor.parse(input) == nil, "\"\(input)\" parsed as a colour")
        }
    }

    @Test("a palette entry is an index and a colour")
    func paletteEntry() {
        let entry = ConfigPalette.parseEntry("5=#BB78D9")
        #expect(entry?.index == 5)
        #expect(entry?.color == ConfigColor(r: 0xBB, g: 0x78, b: 0xD9))
    }

    @Test("a palette index may be decimal, binary, octal or hex")
    func paletteRadix() {
        #expect(ConfigPalette.parseEntry("0b1=#014589")?.index == 1)
        #expect(ConfigPalette.parseEntry("0o7=#234567")?.index == 7)
        #expect(ConfigPalette.parseEntry("0xF=#ABCDEF")?.index == 15)
        #expect(ConfigPalette.parseEntry("255=#000000")?.index == 255)
        // Decimal `10`, not hex — a bare number has no prefix and no doubt.
        #expect(ConfigPalette.parseEntry("10=#000000")?.index == 10)
    }

    @Test("spaces and tabs around either half of a palette entry are ignored")
    func paletteWhitespace() {
        #expect(ConfigPalette.parseEntry("0 =  #AABBCC")?.index == 0)
        #expect(ConfigPalette.parseEntry(" 1= #DDEEFF    ")?.color == ConfigColor(0xDD_EE_FF))
    }

    @Test("an index past 255, a missing equals sign, or a bad colour is not an entry")
    func paletteRejected() {
        #expect(ConfigPalette.parseEntry("256=#000000") == nil)
        #expect(ConfigPalette.parseEntry("-1=#000000") == nil)
        #expect(ConfigPalette.parseEntry("#000000") == nil)
        #expect(ConfigPalette.parseEntry("0=") == nil)
        #expect(ConfigPalette.parseEntry("0=notacolour") == nil)
        #expect(ConfigPalette.parseEntry("=#000000") == nil)
    }

    @Test("cell-foreground and cell-background are colours a cell already has")
    func terminalColor() {
        #expect(ConfigTerminalColor.parse("cell-foreground") == .cellForeground)
        #expect(ConfigTerminalColor.parse("cell-background") == .cellBackground)
        #expect(ConfigTerminalColor.parse("#4e2a84") == .color(ConfigColor(0x4E_2A_84)))
        #expect(ConfigTerminalColor.parse("black") == .color(ConfigColor(r: 0, g: 0, b: 0)))
        #expect(ConfigTerminalColor.parse("a") == nil)
    }
}
