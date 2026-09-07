//  FontConfigTests.swift
//  The font config, as the grid ends up arranged by it.
//
//  Every assertion here is about *order*, because order is the whole of what
//  a font config does and none of it is visible in a pixel. A grid that threw
//  the fallbacks away still draws every ordinary character correctly, and one
//  that took bold from the wrong family still draws bold — just in a typeface
//  the person did not choose, on the machines where the font they did choose
//  has no bold.

import CoreText
import XCTest

@testable import IllogicalConfig

final class FontConfigTests: XCTestCase {
    private static let pointSize: Double = 13
    private static let scale: Double = 2

    private func families(_ grid: FontGrid, _ style: FontStyle) -> [String] {
        grid.faces(style: style).map { CTFontCopyFamilyName($0.font) as String }
    }

    private func grid(_ font: FontConfig) -> FontGrid {
        FontGridSet.grid(font: font, scale: Self.scale)
    }

    // MARK: - The list

    /// The point of a list: the next family is where a codepoint the first
    /// one lacks comes from, so both have to be in the grid and in that
    /// order.
    func testEveryConfiguredFamilyIsInTheGrid() {
        let grid = grid(
            FontConfig(family: nil, pointSize: Self.pointSize)
                .with(regular: ["Menlo", "Courier New"]))
        XCTAssertEqual(
            families(grid, .regular), ["Menlo", "Courier New", "JetBrains Mono"])
    }

    /// The font we ship is a *fallback* behind a configured family, not a
    /// default that a configured family replaces. libghostty adds it in the
    /// same place and for the same stated reason.
    func testTheShippedFontSitsBehindAConfiguredFamily() {
        let grid = grid(FontConfig(family: "Menlo", pointSize: Self.pointSize))
        for style in FontStyle.allCases {
            XCTAssertEqual(families(grid, style).first, "Menlo", "style \(style)")
            XCTAssertEqual(families(grid, style).last, "JetBrains Mono", "style \(style)")
        }
    }

    /// A family nobody has installed is skipped, not substituted.
    ///
    /// `CTFontCreateWithFontDescriptor` hands back Helvetica for a family it
    /// cannot match, so "skipped" is a decision rather than something that
    /// happens on its own — and a proportional face in a terminal grid
    /// mismeasures every cell in it.
    func testAnUninstalledFamilyIsSkipped() {
        let grid = grid(
            FontConfig(family: nil, pointSize: Self.pointSize)
                .with(regular: ["ThisFontIsNotInstalled12345", "Menlo"]))
        XCTAssertEqual(families(grid, .regular), ["Menlo", "JetBrains Mono"])
    }

    /// Nothing configured at all is the font we ship, which is what every
    /// install that has never been configured gets.
    func testNoFamilyIsTheShippedFont() {
        let grid = grid(FontConfig(family: nil, pointSize: Self.pointSize))
        for style in FontStyle.allCases {
            XCTAssertEqual(families(grid, style), ["JetBrains Mono"], "style \(style)")
        }
    }

    // MARK: - Styles

    /// A style whose own family is not installed comes from the *regular*
    /// family, and never from the next family in its own list.
    ///
    /// libghostty is explicit that this is deliberate: "if you set
    /// `font-family-bold = FooBar` and FooBar cannot be found, Ghostty will
    /// use whatever font is set for `font-family` for the bold style." Bold
    /// text in a different typeface than the text around it looks wrong in a
    /// way that a missing bold does not.
    func testAnUninstalledStyleFallsBackToTheRegularFamily() throws {
        let grid = grid(
            FontConfig(family: nil, pointSize: Self.pointSize)
                .with(regular: ["Menlo"], bold: ["ThisFontIsNotInstalled12345"]))
        XCTAssertEqual(families(grid, .bold).first, "Menlo")

        // And it is Menlo's *bold*, not Menlo. Borrowing the family is not
        // the same as giving up on the style.
        let bold = try XCTUnwrap(grid.face(style: .bold))
        XCTAssertTrue(
            CTFontGetSymbolicTraits(bold.font).contains(.traitBold) || bold.syntheticBold != nil)
    }

    /// A style that names an installed family gets it, ahead of the regular
    /// family. The other half of the rule above.
    func testANamedStyleIsUsed() {
        let grid = grid(
            FontConfig(family: nil, pointSize: Self.pointSize)
                .with(regular: ["Menlo"], bold: ["Courier New"]))
        XCTAssertEqual(families(grid, .bold).first, "Courier New")
        XCTAssertEqual(families(grid, .regular).first, "Menlo")
        // Untouched styles still come from the regular family: naming a bold
        // does not drag italic along with it.
        XCTAssertEqual(families(grid, .italic).first, "Menlo")
    }

    // MARK: - Size

    func testFontSizeComesFromTheConfig() {
        let small = grid(FontConfig(family: "Menlo", pointSize: 13))
        let large = grid(FontConfig(family: "Menlo", pointSize: 26))
        XCTAssertEqual(large.pointSize, 26)
        XCTAssertGreaterThan(large.metrics.cellWidth, small.metrics.cellWidth)
        XCTAssertGreaterThan(large.metrics.cellHeight, small.metrics.cellHeight)
    }

    // MARK: - Sharing

    /// Panes that agree about the font share one grid, which is what keeps
    /// four splits from packing the same glyph into four atlases. The font is
    /// part of the key now, so two fonts must not collide.
    func testGridsAreSharedPerFontAndScale() {
        let font = FontConfig(family: "Menlo", pointSize: Self.pointSize)
        XCTAssertIdentical(grid(font), grid(font))
        XCTAssertNotIdentical(
            grid(font), grid(FontConfig(family: "Menlo", pointSize: Self.pointSize + 1)))
        XCTAssertNotIdentical(
            grid(font),
            grid(
                FontConfig(family: nil, pointSize: Self.pointSize)
                    .with(regular: ["Menlo", "Courier New"])))
    }

    // MARK: - Resolution

    /// The ordering, through the code that uses it: a codepoint the
    /// configured family does not have is drawn from the font we ship before
    /// the system cascade is asked for anything.
    ///
    /// The codepoint is searched for rather than hard-coded — which font has
    /// which glyph is a property of the machine, and a literal here would
    /// rot into a test that asserts nothing the first time Apple ships a
    /// wider Menlo.
    func testACodepointMenloLacksComesFromTheShippedFont() throws {
        let grid = grid(FontConfig(family: "Menlo", pointSize: Self.pointSize))
        let menlo = try XCTUnwrap(grid.face(style: .regular))
        let ours = try XCTUnwrap(grid.faces(style: .regular).last)
        XCTAssertEqual(CTFontCopyFamilyName(ours.font) as String, "JetBrains Mono")

        // Sprites are drawn by us whatever the font says, so they can never
        // reach a face and have to come out of the search.
        let candidate = (0x0020...0x2FFF).first { cp in
            let cp = UInt32(cp)
            guard !SpriteFace.hasCodepoint(cp) else { return false }
            let inMenlo = (menlo.glyphIndex(cp) ?? 0) != 0
            let inOurs = (ours.glyphIndex(cp) ?? 0) != 0
            return !inMenlo && inOurs
        }
        let cp = try XCTUnwrap(
            candidate.map(UInt32.init),
            "no codepoint is in JetBrains Mono and not in Menlo on this machine")

        let index = try XCTUnwrap(
            grid.index(codepoint: cp, style: .regular, presentation: nil))
        let resolved = try XCTUnwrap(grid.face(index))
        XCTAssertEqual(CTFontCopyFamilyName(resolved.font) as String, "JetBrains Mono")
    }

    // MARK: - What a test process reads

    /// Nothing here loads a config file, so everything here draws the
    /// defaults. The contract that keeps a render test from depending on
    /// whatever the developer running it happens to have in
    /// `~/.config/illogical/config`.
    func testATestProcessReadsNoConfigFile() {
        XCTAssertEqual(AppConfig.current, Config())
        XCTAssertEqual(AppConfig.font, FontConfig(family: nil, pointSize: 13))
    }
}

extension FontConfig {
    /// A copy with some of the style lists replaced. Only the tests want
    /// this — the app builds one from a whole config — and it keeps each case
    /// above to the one or two lists it is actually about.
    fileprivate func with(
        regular: [String]? = nil, bold: [String]? = nil, italic: [String]? = nil,
        boldItalic: [String]? = nil
    ) -> FontConfig {
        var copy = self
        if let regular { copy.regular = regular }
        if let bold { copy.bold = bold }
        if let italic { copy.italic = italic }
        if let boldItalic { copy.boldItalic = boldItalic }
        return copy
    }
}
