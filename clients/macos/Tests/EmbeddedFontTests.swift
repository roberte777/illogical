//  EmbeddedFontTests.swift
//  The font the app ships, and the four styles it has to cover.
//
//  Two variable files stand in for four faces, and both halves of that trick
//  fail quietly if they break. A bold that lost its `wght` axis is still a
//  legible face, just the wrong weight; an italic that fell through to the
//  synthetic path is still slanted, just sheared rather than drawn. Neither
//  shows up in a pixel test, so assert on the faces themselves.

import CoreText
import XCTest

final class EmbeddedFontTests: XCTestCase {
    private static let pointSize: Double = 13
    private static let scale: Double = 2

    private func defaultGrid() -> FontGrid {
        FontGridSet.grid(family: nil, pointSize: Self.pointSize, scale: Self.scale)
    }

    private func face(_ style: FontStyle) throws -> FontFace {
        try XCTUnwrap(defaultGrid().face(FontIndex(slot: UInt16(style.rawValue))))
    }

    private func weight(_ face: FontFace) -> Double? {
        guard let variation = CTFontCopyVariation(face.font) as? [CFNumber: CFNumber]
        else { return nil }
        for (axis, value) in variation
        where (axis as NSNumber).uint32Value == EmbeddedFont.weightAxis {
            return (value as NSNumber).doubleValue
        }
        return nil
    }

    /// The bundle actually carries the files. Everything below would fall
    /// back to the system's fixed-pitch face without them and still pass
    /// some of its assertions, so check this first and on its own.
    func testBundleCarriesBothVariableFaces() throws {
        XCTAssertNotNil(EmbeddedFont.variable)
        XCTAssertNotNil(EmbeddedFont.variableItalic)
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
        let regular = try XCTUnwrap(grid.face(FontIndex(slot: 0)))
        XCTAssertEqual(CTFontCopyFamilyName(regular.font) as String, "Menlo")
    }

    /// Bold is the upright face with `wght` at 700 — a drawn bold, not an
    /// outline stroked to look like one.
    func testBoldIsTheWeightAxisAndNotSynthetic() throws {
        let bold = try face(.bold)
        XCTAssertEqual(weight(bold), EmbeddedFont.boldWeight)
        XCTAssertTrue(CTFontGetSymbolicTraits(bold.font).contains(.traitBold))
        XCTAssertNil(bold.syntheticBold, "bold should not be stroked")

        // Regular sits at the axis default, wherever the file puts it.
        let regular = try face(.regular)
        XCTAssertNotEqual(weight(regular), EmbeddedFont.boldWeight)
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
        // A descriptor matching by family, resolved against what is
        // installed. The embedded face is not, so this finds nothing —
        // unless the developer happens to have JetBrains Mono installed,
        // in which case the file backing it is theirs and not ours.
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: "JetBrains Mono"] as CFDictionary)
        let matches =
            CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil)
            as? [CTFontDescriptor] ?? []
        let ours = Bundle(for: FontFace.self).bundleURL.standardizedFileURL.path
        for match in matches {
            let url = CTFontDescriptorCopyAttribute(match, kCTFontURLAttribute) as? URL
            XCTAssertFalse(
                url?.standardizedFileURL.path.hasPrefix(ours) ?? false,
                "an embedded face was registered system-wide: \(url?.path ?? "?")")
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
}
