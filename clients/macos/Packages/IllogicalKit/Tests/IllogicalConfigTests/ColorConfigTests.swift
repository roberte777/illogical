//  ColorConfigTests.swift
//  The colour keys, and the one file that has to keep working: a theme.
//
//  A Ghostty theme is a config file with seven keys in it, so the test that
//  matters most here is the last one — a real theme, pasted in whole, read
//  into the fields it is supposed to reach. The rest pin the rules around it:
//  what an empty value does to a key that has no default colour, what the two
//  deprecated invert flags expand to, and that a palette override is
//  remembered as an override rather than merged into an invisible 256-entry
//  array.

import Testing

@testable import IllogicalConfig

@Suite("Colour config")
struct ColorConfigTests {
    private func parse(_ text: String) -> (Config, [ConfigDiagnostic]) {
        var config = Config()
        var diagnostics: [ConfigDiagnostic] = []
        config.apply(text: text, path: "config", diagnostics: &diagnostics)
        config.finalize()
        return (config, diagnostics)
    }

    @Test("the defaults are the app's own colours, not libghostty's")
    func defaults() {
        let config = Config()
        #expect(config.background == ConfigColor(0x0C_1F_2F))
        #expect(config.foreground == ConfigColor(0xC8_D6_E0))
        #expect(config.cursorColor == nil)
        #expect(config.cursorText == nil)
        #expect(config.selectionBackground == nil)
        #expect(config.selectionForeground == nil)
        #expect(config.palette.isEmpty)
        #expect(config.paletteGenerate == false)
        #expect(config.paletteHarmonious == false)
        #expect(config.minimumContrast == 1)
    }

    @Test("background and foreground take any colour syntax")
    func groundColors() {
        let (config, diagnostics) = parse(
            """
            background = #1e1e2e
            foreground = cornflower blue
            """)
        #expect(config.background == ConfigColor(0x1E_1E_2E))
        #expect(config.foreground == ConfigColor(r: 100, g: 149, b: 237))
        #expect(diagnostics.isEmpty)
    }

    @Test("a colour that does not parse is reported and changes nothing")
    func invalidColor() {
        let (config, diagnostics) = parse("background = #ggg")
        #expect(config.background == Config().background)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].description == "config:1:background: invalid value \"#ggg\"")
    }

    @Test("an empty value resets background and unsets the four that have no default")
    func reset() {
        let (config, diagnostics) = parse(
            """
            background = #ffffff
            cursor-color = #ff0000
            selection-background = #00ff00
            background =
            cursor-color =
            selection-background =
            """)
        #expect(config.background == Config().background)
        #expect(config.cursorColor == nil)
        #expect(config.selectionBackground == nil)
        #expect(diagnostics.isEmpty)
    }

    @Test("the cursor and selection colours take cell-foreground and cell-background")
    func cellColors() {
        let (config, diagnostics) = parse(
            """
            cursor-color = cell-foreground
            cursor-text = cell-background
            selection-background = cell-foreground
            selection-foreground = #1e1e2e
            """)
        #expect(config.cursorColor == .cellForeground)
        #expect(config.cursorText == .cellBackground)
        #expect(config.selectionBackground == .cellForeground)
        #expect(config.selectionForeground == .color(ConfigColor(0x1E_1E_2E)))
        #expect(diagnostics.isEmpty)
    }

    @Test("palette remembers which indices were overridden, and nothing else")
    func palette() {
        let (config, diagnostics) = parse(
            """
            palette = 0=#45475a
            palette = 0xF=#a6adc8
            """)
        #expect(config.palette[0] == ConfigColor(0x45_47_5A))
        #expect(config.palette[15] == ConfigColor(0xA6_AD_C8))
        // Untouched indices are libghostty's, and this package does not
        // pretend to know them.
        #expect(config.palette[1] == nil)
        #expect(config.palette.overrides.count == 2)
        #expect(diagnostics.isEmpty)
    }

    @Test("an empty palette clears every override, so a later file can replace one")
    func paletteReset() {
        let (config, _) = parse(
            """
            palette = 0=#45475a
            palette =
            palette = 1=#f38ba8
            """)
        #expect(config.palette[0] == nil)
        #expect(config.palette[1] == ConfigColor(0xF3_8B_A8))
    }

    @Test("a bad palette entry is reported and leaves the others alone")
    func paletteInvalid() {
        let (config, diagnostics) = parse(
            """
            palette = 0=#45475a
            palette = 256=#000000
            """)
        #expect(config.palette[0] == ConfigColor(0x45_47_5A))
        #expect(config.palette.overrides.count == 1)
        #expect(diagnostics.count == 1)
    }

    @Test("the flags read libghostty's spellings of true and false, and only those")
    func flags() {
        #expect(parse("palette-generate = true").0.paletteGenerate == true)
        #expect(parse("palette-generate = 1").0.paletteGenerate == true)
        #expect(parse("palette-generate = t").0.paletteGenerate == true)
        #expect(parse("palette-generate = T").0.paletteGenerate == true)
        #expect(parse("palette-harmonious = false").0.paletteHarmonious == false)
        #expect(parse("palette-harmonious = 0").0.paletteHarmonious == false)

        let (config, diagnostics) = parse("palette-generate = yes")
        #expect(config.paletteGenerate == false)
        #expect(diagnostics.count == 1)
    }

    @Test("minimum-contrast is clamped to the range a WCAG ratio has")
    func minimumContrast() {
        #expect(parse("minimum-contrast = 3").0.minimumContrast == 3)
        #expect(parse("minimum-contrast = 1.1").0.minimumContrast == 1.1)
        #expect(parse("minimum-contrast = 0").0.minimumContrast == 1)
        #expect(parse("minimum-contrast = 100").0.minimumContrast == 21)
        #expect(parse("minimum-contrast = lots").1.count == 1)
    }

    @Test("cursor-invert-fg-bg is the pair of cell colours it was replaced by")
    func cursorInvertCompat() {
        let (config, diagnostics) = parse("cursor-invert-fg-bg = true")
        #expect(config.cursorColor == .cellForeground)
        #expect(config.cursorText == .cellBackground)
        #expect(diagnostics.isEmpty)
    }

    @Test("selection-invert-fg-bg is too, and inverts the other way round")
    func selectionInvertCompat() {
        let (config, diagnostics) = parse("selection-invert-fg-bg = true")
        #expect(config.selectionBackground == .cellForeground)
        #expect(config.selectionForeground == .cellBackground)
        #expect(diagnostics.isEmpty)
    }

    @Test("a bare invert flag means true, and a false one sets nothing")
    func invertCompatEdges() {
        // A bare key is an error for a real option and a `true` for these,
        // which is libghostty's rule: they were flags before they were keys.
        #expect(parse("cursor-invert-fg-bg").0.cursorColor == .cellForeground)
        // False has nothing to undo — there is no field behind the key — so it
        // leaves whatever the config already said.
        let (config, diagnostics) = parse(
            """
            cursor-color = #ff0000
            cursor-invert-fg-bg = false
            """)
        #expect(config.cursorColor == .color(ConfigColor(0xFF_00_00)))
        #expect(diagnostics.isEmpty)
    }

    @Test("a Ghostty theme file reads into the fields it names")
    func themeFile() {
        // Catppuccin Mocha, copied from the collection the app ships. Every
        // theme in it is exactly these seven keys.
        let (config, diagnostics) = parse(
            """
            palette = 0=#45475a
            palette = 1=#f38ba8
            palette = 7=#bac2de
            palette = 8=#585b70
            palette = 15=#a6adc8
            background = #1e1e2e
            foreground = #cdd6f4
            cursor-color = #f5e0dc
            cursor-text = #1e1e2e
            selection-background = #f5e0dc
            selection-foreground = #1e1e2e
            """)
        #expect(diagnostics.isEmpty)
        #expect(config.background == ConfigColor(0x1E_1E_2E))
        #expect(config.foreground == ConfigColor(0xCD_D6_F4))
        #expect(config.cursorColor == .color(ConfigColor(0xF5_E0_DC)))
        #expect(config.cursorText == .color(ConfigColor(0x1E_1E_2E)))
        #expect(config.selectionBackground == .color(ConfigColor(0xF5_E0_DC)))
        #expect(config.selectionForeground == .color(ConfigColor(0x1E_1E_2E)))
        #expect(config.palette[0] == ConfigColor(0x45_47_5A))
        #expect(config.palette[15] == ConfigColor(0xA6_AD_C8))
    }
}
