//  EmbeddedFontTests.swift
//  The fonts the app ships: the text face and its four styles, and the Nerd
//  Font symbols behind them.
//
//  Two variable files stand in for four faces, and both halves of that trick
//  fail quietly if they break. A bold that lost its `wght` axis is still a
//  legible face, just the wrong weight; an italic that fell through to the
//  synthetic path is still slanted, just sheared rather than drawn. Neither
//  shows up in a pixel test, so assert on the faces themselves.
//
//  The third file is the symbols, and what it has to get right is the
//  fallback order: behind the text face, behind every configured family,
//  and never the face a grid measures its cells from. Each of those is an
//  ordering in `FontGrid.build`, and each one fails as text drawn from the
//  wrong face rather than as anything a compiler would notice.

import CoreText
import XCTest

final class EmbeddedFontTests: XCTestCase {
    private static let pointSize: Double = 13
    private static let scale: Double = 2

    private func defaultGrid() -> FontGrid {
        FontGridSet.grid(family: nil, pointSize: Self.pointSize, scale: Self.scale)
    }

    /// The face a style is drawn with before any fallback: what the grid
    /// resolves the style to, rather than a slot number. Slots stopped being
    /// one-per-style when a family became a list.
    private func face(_ style: FontStyle) throws -> FontFace {
        try XCTUnwrap(defaultGrid().face(style: style))
    }

    /// The face's `wght`, falling back to the axis default when the face
    /// carries no variation dictionary — an unvaried face sits at its
    /// default, and reporting nil for it would make "no weight axis at all"
    /// and "not bold" the same answer.
    private func weight(_ face: FontFace) -> Double? {
        if let variation = CTFontCopyVariation(face.font) as? [CFNumber: CFNumber] {
            for (axis, value) in variation
            where (axis as NSNumber).uint32Value == EmbeddedFont.weightAxis {
                return (value as NSNumber).doubleValue
            }
        }
        guard let axes = CTFontCopyVariationAxes(face.font) as? [[CFString: Any]]
        else { return nil }
        for axis in axes
        where (axis[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value
            == EmbeddedFont.weightAxis
        {
            return (axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber)?.doubleValue
        }
        return nil
    }

    /// The bundle actually carries the files. Everything below would fall
    /// back to the system's fixed-pitch face without them and still pass
    /// some of its assertions, so check this first and on its own.
    ///
    /// Walking `allCases` rather than the named properties so that a face
    /// added to `Resource` is covered the moment it exists.
    func testBundleCarriesEveryEmbeddedFace() throws {
        for resource in EmbeddedFont.Resource.allCases {
            XCTAssertNotNil(
                EmbeddedFont.font(resource), "\(resource.rawValue).ttf is not in the bundle")
        }
        XCTAssertNotNil(EmbeddedFont.variable)
        XCTAssertNotNil(EmbeddedFont.variableItalic)
        XCTAssertNotNil(EmbeddedFont.symbols)
    }

    /// No configured family resolves to what we ship, not to Menlo or SF
    /// Mono. This is the whole point of embedding it.
    func testDefaultFamilyIsTheEmbeddedFont() throws {
        for style in FontStyle.allCases {
            let name = CTFontCopyFamilyName(try face(style).font) as String
            XCTAssertEqual(name, "JetBrains Mono", "style \(style)")
        }
    }

    /// A named family still wins, so the embedded font is a default and not
    /// a hard-coding.
    func testNamedFamilyStillWins() throws {
        let grid = FontGridSet.grid(family: "Menlo", pointSize: Self.pointSize, scale: Self.scale)
        let regular = try XCTUnwrap(grid.face(style: .regular))
        XCTAssertEqual(CTFontCopyFamilyName(regular.font) as String, "Menlo")
    }

    /// A family the system does not have falls through to the font we ship
    /// rather than to CoreText's substitute.
    ///
    /// `CTFontCreateWithFontDescriptor` cannot fail — asked for a family
    /// nothing matches it hands back Helvetica, which is proportional, so
    /// without the match check every cell in the grid would be measured off
    /// the wrong advance.
    func testAnUnavailableFamilyFallsBackToWhatWeShip() throws {
        let grid = FontGridSet.grid(
            family: "ThisFontIsNotInstalled12345", pointSize: Self.pointSize, scale: Self.scale)
        let regular = try XCTUnwrap(grid.face(style: .regular))
        XCTAssertEqual(CTFontCopyFamilyName(regular.font) as String, "JetBrains Mono")
    }

    /// Bold is the upright face with `wght` at 700 — a drawn bold, not an
    /// outline stroked to look like one.
    func testBoldIsTheWeightAxisAndNotSynthetic() throws {
        let bold = try face(.bold)
        XCTAssertEqual(weight(bold), EmbeddedFont.boldWeight)
        XCTAssertTrue(CTFontGetSymbolicTraits(bold.font).contains(.traitBold))
        XCTAssertNil(bold.syntheticBold, "bold should not be stroked")

        // Regular sits at the axis default, wherever the file puts it —
        // but it does have to *have* the axis, or the face is not the
        // variable one we shipped.
        let regular = try face(.regular)
        let regularWeight = try XCTUnwrap(weight(regular), "regular has no weight axis")
        XCTAssertLessThan(regularWeight, EmbeddedFont.boldWeight)
        XCTAssertNil(regular.syntheticBold)
    }

    /// Italic comes from the italic file. Asking CoreText for the italic
    /// trait on the upright variable face hands back the upright face, so a
    /// regression here lands on the synthetic skew instead.
    func testItalicIsTheRealFaceAndNotSkewed() throws {
        for style in [FontStyle.italic, .boldItalic] {
            let f = try face(style)
            XCTAssertTrue(
                CTFontGetSymbolicTraits(f.font).contains(.traitItalic), "style \(style)")
            // The synthetic path copies the face with `italicSkew` as its
            // matrix; a real italic keeps the identity.
            XCTAssertEqual(CTFontGetMatrix(f.font).c, 0, accuracy: 1e-9, "style \(style)")
            XCTAssertNil(f.syntheticBold, "style \(style)")
        }
        XCTAssertEqual(weight(try face(.boldItalic)), EmbeddedFont.boldWeight)
        XCTAssertNotEqual(weight(try face(.italic)), EmbeddedFont.boldWeight)
    }

    /// Bold has to be visibly heavier than regular, which is the assertion
    /// that would catch the axis being applied to the wrong tag or being
    /// silently ignored.
    func testBoldDrawsHeavierThanRegular() throws {
        func inkWidth(_ face: FontFace) throws -> Double {
            let glyph = try XCTUnwrap(face.glyphIndex(UInt32(UnicodeScalar("M").value)))
            var glyphs = [CGGlyph(truncatingIfNeeded: glyph)]
            let bounds = CTFontGetBoundingRectsForGlyphs(
                face.font, .horizontal, &glyphs, nil, 1)
            return Double(bounds.width)
        }
        XCTAssertGreaterThan(try inkWidth(face(.bold)), try inkWidth(face(.regular)))
        XCTAssertGreaterThan(try inkWidth(face(.boldItalic)), try inkWidth(face(.italic)))
    }

    /// All four styles are one family at one size, so they share a cell.
    /// A grid whose bold advanced differently would tear every bold run.
    func testEveryStyleSharesTheAdvance() throws {
        func advance(_ face: FontFace) throws -> Double {
            let glyph = try XCTUnwrap(face.glyphIndex(UInt32(UnicodeScalar("M").value)))
            var glyphs = [CGGlyph(truncatingIfNeeded: glyph)]
            return CTFontGetAdvancesForGlyphs(face.font, .horizontal, &glyphs, nil, 1)
        }
        let regular = try advance(face(.regular))
        XCTAssertGreaterThan(regular, 0)
        for style in FontStyle.allCases {
            XCTAssertEqual(try advance(face(style)), regular, accuracy: 1e-9, "style \(style)")
        }
    }

    /// The faces are never handed to `CTFontManager`, so they must not turn
    /// up in the user's font list. Registering them would leak the app's
    /// font into every other program on the machine.
    func testEmbeddedFacesAreNotRegisteredWithTheSystem() throws {
        // Force the faces to exist first. Without this the test asserts
        // nothing when run on its own: nothing has parsed a font, so there
        // is no registration to catch, and it would pass against an
        // implementation that registers on load.
        XCTAssertNotNil(EmbeddedFont.variable)
        XCTAssertNotNil(EmbeddedFont.variableItalic)
        XCTAssertNotNil(EmbeddedFont.symbols)

        // A descriptor matching by family, resolved against what is
        // installed. The embedded faces are not, so this finds nothing —
        // unless the developer happens to have the family installed, in
        // which case the file backing it is theirs and not ours.
        let ours = Bundle(for: FontFace.self).bundleURL.standardizedFileURL.path
        for family in ["JetBrains Mono", "Symbols Nerd Font"] {
            let descriptor = CTFontDescriptorCreateWithAttributes(
                [kCTFontFamilyNameAttribute: family] as CFDictionary)
            let matches =
                CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil)
                as? [CTFontDescriptor] ?? []
            for match in matches {
                let url = CTFontDescriptorCopyAttribute(match, kCTFontURLAttribute) as? URL
                XCTAssertFalse(
                    url?.standardizedFileURL.path.hasPrefix(ours) ?? false,
                    "an embedded face was registered system-wide: \(url?.path ?? "?")")
            }
        }
    }

    /// The shipped font, through the whole pipeline: shaped, rasterized into
    /// the atlas, drawn by Metal. Everything above asserts on faces, which
    /// would all still hold if the glyphs never reached a pixel.
    ///
    /// Bold carrying more ink than regular is the assertion that matters —
    /// it is the only one that can tell a `wght` axis that was applied from
    /// one that was set on a descriptor and then dropped on the way down.
    func testTheShippedFontRendersAndBoldIsHeavier() throws {
        let text = "MMMMMMMM"
        let harness = try RenderHarness(columns: text.count + 2, rows: 4, family: nil)
        let source = harness.source
        source.write(text, row: 0, column: 1)
        source.write(text, row: 1, column: 1, flags: [.bold])
        source.write(text, row: 2, column: 1, flags: [.italic])
        source.write(text, row: 3, column: 1, flags: [.bold, .italic])

        let image = try harness.render()
        image.dump(named: "embedded-font")

        let background = ColorMath.expected(source.snapshot.background)
        func ink(_ row: Int) -> Int {
            image.countDiffering(
                from: background, x: 0, y: row * harness.cellHeight,
                w: image.width, h: harness.cellHeight)
        }

        for row in 0..<4 { XCTAssertGreaterThan(ink(row), 0, "row \(row) drew nothing") }
        XCTAssertGreaterThan(ink(1), ink(0), "bold should lay down more ink than regular")
        XCTAssertGreaterThan(ink(3), ink(2), "bold italic should be heavier than italic")
    }

    /// Metrics come off the embedded face, and a grid built from it has to
    /// be a usable cell rather than a degenerate one.
    func testGridMetricsAreSane() throws {
        let metrics = defaultGrid().metrics
        XCTAssertGreaterThan(metrics.cellWidth, 0)
        XCTAssertGreaterThan(metrics.cellHeight, metrics.cellWidth)
        XCTAssertGreaterThan(metrics.cellBaseline, 0)
        XCTAssertLessThan(metrics.cellBaseline, metrics.cellHeight)
    }

    // MARK: - Nerd Font symbols

    /// Codepoints from the icon sets Neovim's plugins draw with: a Seti
    /// folder, a devicon, Font Awesome's folder and a Material Design icon
    /// off the supplementary plane. None is in JetBrains Mono; all are in
    /// the symbols face.
    private static let icons: [UInt32] = [0xE5FF, 0xE7C5, 0xF07B, 0xF0388]

    private func family(of index: FontIndex, in grid: FontGrid) throws -> String {
        CTFontCopyFamilyName(try XCTUnwrap(grid.face(index)).font) as String
    }

    /// A Nerd Font icon resolves to the symbols face we ship, in every
    /// style. Before that file was in the bundle the cascade was asked and,
    /// on a machine with no Nerd Font installed, came back empty — a blank
    /// cell where Neovim's file tree wanted a folder.
    func testNerdFontIconsResolveToTheSymbolsFace() throws {
        let grid = defaultGrid()
        for style in FontStyle.allCases {
            for cp in Self.icons {
                let index = try XCTUnwrap(
                    grid.index(codepoint: cp, style: style, presentation: nil),
                    "U+\(String(cp, radix: 16, uppercase: true)) resolved to nothing in \(style)")
                XCTAssertFalse(index.isSprite)
                XCTAssertEqual(
                    try family(of: index, in: grid), "Symbols Nerd Font", "style \(style)")
            }
        }
    }

    /// One slot for all four styles. Icons have no bold or italic, and a
    /// slot per style would rasterize the same folder four times into the
    /// atlas.
    func testTheSymbolsFaceIsOneSlotSharedByEveryStyle() throws {
        let grid = defaultGrid()
        let regular = try XCTUnwrap(
            grid.index(codepoint: 0xF07B, style: .regular, presentation: nil))
        for style in FontStyle.allCases {
            XCTAssertEqual(
                grid.index(codepoint: 0xF07B, style: style, presentation: nil), regular,
                "style \(style)")
        }
    }

    /// The symbols face sits behind the text face, not beside it. U+26A1 is
    /// in both, and JetBrains Mono's is the one drawn: the face that sets
    /// the cell metrics should draw everything it can.
    func testTheTextFaceWinsWhereBothHaveTheGlyph() throws {
        let grid = defaultGrid()
        let bolt: UInt32 = 0x26A1
        for style in FontStyle.allCases {
            let text = try XCTUnwrap(grid.face(style: style))
            XCTAssertTrue(text.hasCodepoint(bolt), "JetBrains Mono lost U+26A1; pick another")
            let index = try XCTUnwrap(
                grid.index(codepoint: bolt, style: style, presentation: nil))
            XCTAssertEqual(try family(of: index, in: grid), "JetBrains Mono", "style \(style)")
        }
    }

    /// The icons survive a configured family. This is why the symbols are
    /// a file of their own rather than a patched JetBrains Mono: someone
    /// who names Menlo still gets a folder in their file tree.
    func testIconsSurviveANamedFamily() throws {
        let grid = FontGridSet.grid(family: "Menlo", pointSize: Self.pointSize, scale: Self.scale)
        let regular = try XCTUnwrap(grid.face(style: .regular))
        XCTAssertEqual(CTFontCopyFamilyName(regular.font) as String, "Menlo")
        for cp in Self.icons {
            let index = try XCTUnwrap(
                grid.index(codepoint: cp, style: .regular, presentation: nil))
            XCTAssertEqual(try family(of: index, in: grid), "Symbols Nerd Font")
        }
    }

    /// Last in every style's search order, and never first: `metrics` is
    /// read off the first regular face, and a grid measured against a
    /// symbols-only font would have no cell to speak of.
    func testTheSymbolsFaceIsLastAndNeverFirst() throws {
        let grid = defaultGrid()
        for style in FontStyle.allCases {
            let faces = grid.faces(style: style)
            XCTAssertGreaterThan(faces.count, 1, "style \(style)")
            XCTAssertEqual(
                CTFontCopyFamilyName(try XCTUnwrap(faces.first).font) as String,
                "JetBrains Mono", "style \(style)")
            XCTAssertEqual(
                CTFontCopyFamilyName(try XCTUnwrap(faces.last).font) as String,
                "Symbols Nerd Font", "style \(style)")
        }
    }

    /// Through the whole pipeline: shaped, constrained to the cell,
    /// rasterized, drawn. Every icon cell has to carry ink, and the empty
    /// cell to the left of the first must not — the symbols file is the
    /// unpatched one, so fitting an icon to its cell is `NerdFontConstraints`'
    /// job, and a constraint that stopped applying would show up as ink
    /// where no glyph was written.
    func testNerdFontIconsReachThePixels() throws {
        let icons = Self.icons.compactMap(Unicode.Scalar.init).map(String.init)
        let harness = try RenderHarness(columns: icons.count + 2, rows: 1, family: nil)
        for (i, icon) in icons.enumerated() {
            harness.source.write(icon, row: 0, column: 1 + i)
        }
        let image = try harness.render()
        image.dump(named: "nerd-font-symbols")

        let background = ColorMath.expected(harness.source.snapshot.background)
        func ink(column: Int) -> Int {
            let r = harness.cellRect(column: column, row: 0)
            return image.countDiffering(from: background, x: r.x, y: r.y, w: r.w, h: r.h)
        }
        XCTAssertEqual(ink(column: 0), 0, "an icon spilled into the cell to its left")
        for i in 0..<icons.count {
            XCTAssertGreaterThan(ink(column: 1 + i), 0, "icon \(i) drew nothing")
        }
    }
}
