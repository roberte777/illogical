//  FontConfigTests.swift
//  The font keys, with libghostty's semantics.
//
//  Three of these are decisions rather than behaviour — repeating appends,
//  `""` resets, and a style is searched for inside the family you named —
//  and all three are annoying to change once anyone has written a config
//  file. That is what makes them worth a test each.

import Testing

@testable import IllogicalConfig

@Suite("Font config")
struct FontConfigTests {
    /// Apply `text` to a fresh config, finalize it, and hand back both it and
    /// whatever went wrong.
    private func parse(_ text: String) -> (Config, [ConfigDiagnostic]) {
        var config = Config()
        var diagnostics: [ConfigDiagnostic] = []
        config.apply(text: text, path: "config", diagnostics: &diagnostics)
        config.finalize()
        return (config, diagnostics)
    }

    @Test("defaults name no family and 13 points")
    func defaults() {
        let config = Config()
        #expect(config.fontFamily.isEmpty)
        #expect(config.fontSize == 13)
    }

    @Test("font-family repeats to build a fallback list, in order")
    func repeats() {
        let (config, diagnostics) = parse(
            """
            font-family = Berkeley Mono
            font-family = Noto Sans CJK
            """)
        #expect(config.fontFamily == ["Berkeley Mono", "Noto Sans CJK"])
        #expect(diagnostics.isEmpty)
    }

    @Test("an empty value resets the list, so a later value replaces rather than appends")
    func reset() {
        let (config, _) = parse(
            """
            font-family = Berkeley Mono
            font-family = ""
            font-family = Iosevka
            """)
        #expect(config.fontFamily == ["Iosevka"])
    }

    @Test("a bare key with no equals sign is an error, not a reset")
    func valueRequired() {
        let (config, diagnostics) = parse(
            """
            font-family = Iosevka
            font-family
            """)
        #expect(config.fontFamily == ["Iosevka"])
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message == "value required")
        #expect(diagnostics.first?.line == 2)
    }

    @Test("a named family fills in the styles it did not name")
    func stylesInheritTheFamily() {
        let (config, _) = parse("font-family = Berkeley Mono")
        #expect(config.fontFamilyBold == ["Berkeley Mono"])
        #expect(config.fontFamilyItalic == ["Berkeley Mono"])
        #expect(config.fontFamilyBoldItalic == ["Berkeley Mono"])
    }

    @Test("a style that was named keeps what it was given")
    func namedStyleWins() {
        let (config, _) = parse(
            """
            font-family = Berkeley Mono
            font-family-italic = Iosevka Oblique
            """)
        #expect(config.fontFamilyItalic == ["Iosevka Oblique"])
        // The other two still come from the regular family, which is the
        // point: a named italic does not drag bold along with it.
        #expect(config.fontFamilyBold == ["Berkeley Mono"])
        #expect(config.fontFamilyBoldItalic == ["Berkeley Mono"])
    }

    @Test("no family at all leaves every style empty")
    func noFamilyLeavesStylesEmpty() {
        // Empty is what the renderer reads as "the font the app ships", so
        // finalize must not turn it into anything else.
        let (config, _) = parse("font-size = 14")
        #expect(config.fontFamily.isEmpty)
        #expect(config.fontFamilyBold.isEmpty)
    }

    @Test("font-size takes fractional points")
    func fontSize() {
        #expect(parse("font-size = 14").0.fontSize == 14)
        #expect(parse("font-size = 13.5").0.fontSize == 13.5)
    }

    @Test("an empty font-size resets it to the default")
    func fontSizeReset() {
        let (config, diagnostics) = parse(
            """
            font-size = 20
            font-size =
            """)
        #expect(config.fontSize == 13)
        #expect(diagnostics.isEmpty)
    }

    @Test("a font-size that is not a positive number is refused, and the old one kept")
    func fontSizeInvalid() {
        // `13,5` because `Double(_:)` is not locale-aware and must not be:
        // a comma is a typo here, not a decimal separator. `nan` and `inf`
        // parse as doubles and are still not sizes.
        for value in ["abc", "0", "-3", "13,5", "nan", "inf"] {
            let (config, diagnostics) = parse(
                """
                font-size = 20
                font-size = \(value)
                """)
            #expect(config.fontSize == 20, "\(value) should not have been accepted")
            #expect(diagnostics.first?.message == "invalid value \"\(value)\"")
        }
    }

    @Test("an unknown key is reported with its line and its spelling")
    func unknownField() {
        let (_, diagnostics) = parse(
            """
            font-family = Iosevka
            font-famly = Iosevka
            """)
        #expect(diagnostics.count == 1)
        let diagnostic = diagnostics[0]
        #expect(diagnostic.key == "font-famly")
        #expect(diagnostic.message == "unknown field")
        #expect(diagnostic.description == "config:2:font-famly: unknown field")
    }

    @Test("a bad line does not stop the ones after it")
    func badLinesAreSkipped() {
        let (config, diagnostics) = parse(
            """
            nonsense = yes
            font-size = 16
            """)
        #expect(config.fontSize == 16)
        #expect(diagnostics.count == 1)
    }
}
