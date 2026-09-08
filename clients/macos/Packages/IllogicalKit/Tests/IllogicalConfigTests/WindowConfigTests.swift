//  WindowConfigTests.swift
//  `background-opacity` and `background-blur`.
//
//  Two keys, and most of what is worth testing about them is the second one's
//  spelling: libghostty takes a bool *or* a radius there, and a Ghostty config
//  pasted into this app has to keep meaning what it meant. The rest is the
//  pair of rules every key here follows — an empty value resets, a bare key is
//  an error — checked once on these two because they are the first numeric and
//  boolean options in the file.

import Testing

@testable import IllogicalConfig

@Suite("Window config")
struct WindowConfigTests {
    private func parse(_ text: String) -> (Config, [ConfigDiagnostic]) {
        var config = Config()
        var diagnostics: [ConfigDiagnostic] = []
        config.apply(text: text, path: "config", diagnostics: &diagnostics)
        config.finalize()
        return (config, diagnostics)
    }

    @Test("the default window is opaque and unblurred")
    func defaults() {
        let config = Config()
        #expect(config.backgroundOpacity == 1)
        #expect(config.backgroundBlurRadius == 0)
    }

    @Test("background-opacity reads a fraction")
    func opacity() {
        let (config, diagnostics) = parse("background-opacity = 0.85")
        #expect(config.backgroundOpacity == 0.85)
        #expect(diagnostics.isEmpty)
    }

    @Test("an opacity outside 0...1 is clamped rather than refused")
    func opacityClamped() {
        #expect(parse("background-opacity = 50").0.backgroundOpacity == 1)
        #expect(parse("background-opacity = -3").0.backgroundOpacity == 0)
    }

    @Test("a non-numeric opacity is reported and changes nothing")
    func opacityInvalid() {
        let (config, diagnostics) = parse("background-opacity = mostly")
        #expect(config.backgroundOpacity == 1)
        #expect(diagnostics.count == 1)
    }

    @Test("background-blur takes a bool, and true is libghostty's radius of 20")
    func blurBool() {
        #expect(parse("background-blur = true").0.backgroundBlurRadius == 20)
        #expect(parse("background-blur = yes").0.backgroundBlurRadius == 20)
        #expect(parse("background-blur = false").0.backgroundBlurRadius == 0)
    }

    @Test("background-blur also takes a radius, which is what Ghostty configs write")
    func blurRadius() {
        #expect(parse("background-blur = 30").0.backgroundBlurRadius == 30)
        // Zero is the one value both readings agree on.
        #expect(parse("background-blur = 0").0.backgroundBlurRadius == 0)
    }

    @Test("background-blur-radius is the same key under Ghostty's other name")
    func blurRadiusAlias() {
        let (config, diagnostics) = parse("background-blur-radius = 12")
        #expect(config.backgroundBlurRadius == 12)
        #expect(diagnostics.isEmpty)
    }

    @Test("an absurd radius is capped rather than handed to the window server")
    func blurCapped() {
        #expect(parse("background-blur = 100000").0.backgroundBlurRadius == 255)
    }

    @Test("a blur that is neither a bool nor a number is reported")
    func blurInvalid() {
        let (config, diagnostics) = parse("background-blur = quite")
        #expect(config.backgroundBlurRadius == 0)
        #expect(diagnostics.count == 1)
    }

    @Test("an empty value resets both keys to their defaults")
    func reset() {
        let (config, diagnostics) = parse(
            """
            background-opacity = 0.5
            background-blur = 30
            background-opacity =
            background-blur =
            """)
        #expect(config.backgroundOpacity == 1)
        #expect(config.backgroundBlurRadius == 0)
        #expect(diagnostics.isEmpty)
    }

    @Test("a bare key with no equals sign is an error, not a reset")
    func valueRequired() {
        let (config, diagnostics) = parse(
            """
            background-opacity = 0.5
            background-opacity
            """)
        #expect(config.backgroundOpacity == 0.5)
        #expect(diagnostics.count == 1)
    }
}
