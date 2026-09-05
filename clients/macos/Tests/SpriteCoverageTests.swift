//  SpriteCoverageTests.swift
//  Every codepoint we claim to draw must actually draw something.
//
//  The sprite dispatch is a stack of range checks feeding a stack of
//  switches, and the easy way to break it is to claim a range in
//  `hasCodepoint` and then fall through the switch that draws it — which
//  produces a blank cell, not a crash. Sweeping the ranges catches that.

import XCTest

final class SpriteCoverageTests: XCTestCase {
    /// Codepoints that are legitimately blank.
    ///
    /// U+1FB93 is an unallocated hole in the Symbols for Legacy Computing
    /// block; libghostty renders it empty on purpose and so do we.
    private static let expectedBlank: Set<UInt32> = [0x1FB93]

    private func assertAllDraw(
        _ range: ClosedRange<UInt32>, _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let grid = FontGridSet.grid(family: "Menlo", pointSize: 26, scale: 2)
        var blank: [String] = []
        for cp in range {
            guard SpriteFace.hasCodepoint(cp) else { continue }
            let render = try grid.renderGlyph(
                .sprite, glyph: cp, options: GlyphRenderOptions(cellWidth: 1))
            if render.glyph.isEmpty && !Self.expectedBlank.contains(cp) {
                blank.append(String(format: "U+%04X", cp))
            }
        }
        XCTAssertTrue(
            blank.isEmpty, "\(name): drew nothing for \(blank.joined(separator: " "))",
            file: file, line: line)
    }

    func testBoxDrawing() throws { try assertAllDraw(0x2500...0x257F, "box drawing") }
    func testBlockElements() throws { try assertAllDraw(0x2580...0x259F, "block elements") }
    func testGeometricShapes() throws { try assertAllDraw(0x25E2...0x25FF, "geometric") }

    /// U+2800 is BRAILLE PATTERN BLANK and really is blank, so start at 2801.
    func testBraille() throws { try assertAllDraw(0x2801...0x28FF, "braille") }

    func testPowerline() throws { try assertAllDraw(0xE0B0...0xE0D4, "powerline") }
    func testBranchDrawing() throws { try assertAllDraw(0xF5D0...0xF60D, "branch drawing") }
    func testLegacyComputing() throws { try assertAllDraw(0x1FB00...0x1FBEF, "legacy computing") }
    func testLegacySupplement() throws {
        try assertAllDraw(0x1CC00...0x1CEAF, "legacy supplement")
    }

    /// The sprite face must not claim codepoints it can't draw, or ordinary
    /// text would silently lose its glyphs to a blank sprite.
    func testDoesNotClaimOrdinaryText() {
        for cp in UInt32(0x20)...UInt32(0x7E) {
            XCTAssertFalse(SpriteFace.hasCodepoint(cp), "claimed ASCII U+\(String(cp, radix: 16))")
        }
        // A few from blocks adjacent to ones we do claim.
        for cp: UInt32 in [0x24FF, 0x2600, 0x27FF, 0x2FFF, 0x1FBF0, 0x1CEB0, 0xF60E, 0xE0D8] {
            XCTAssertFalse(
                SpriteFace.hasCodepoint(cp),
                "claimed U+\(String(cp, radix: 16, uppercase: true))")
        }
    }

    /// Sextants divide the cell into a 2x3 grid. SEXTANT-1 is the top-left
    /// sixth and nothing else.
    func testSextantOneIsTopLeftSixth() throws {
        let h = try RenderHarness(columns: 1, rows: 1, pointSize: 26)
        h.source.write("\u{1FB00}", row: 0)
        let image = try h.render()
        let bg = ColorMath.expected(h.source.snapshot.background)

        let halfW = h.cellWidth / 2
        let thirdH = h.cellHeight / 3
        XCTAssertGreaterThan(
            image.countDiffering(from: bg, x: 0, y: 0, w: halfW, h: thirdH - 1), 0,
            "the top-left sixth is empty")
        XCTAssertEqual(
            image.countDiffering(
                from: bg, x: halfW + 1, y: 0, w: h.cellWidth - halfW - 1, h: h.cellHeight),
            0, "ink in the right half")
        XCTAssertEqual(
            image.countDiffering(
                from: bg, x: 0, y: thirdH + 1, w: h.cellWidth, h: h.cellHeight - thirdH - 1),
            0, "ink below the top third")
    }

    /// Octants divide the cell into a 2x4 grid. U+1CD00 is OCTANT-3, which is
    /// the left cell of the second row.
    func testOctantThreeIsSecondRowLeft() throws {
        let h = try RenderHarness(columns: 1, rows: 1, pointSize: 26)
        h.source.write("\u{1CD00}", row: 0)
        let image = try h.render()
        let bg = ColorMath.expected(h.source.snapshot.background)

        let halfW = h.cellWidth / 2
        let quarterH = h.cellHeight / 4
        XCTAssertGreaterThan(
            image.countDiffering(from: bg, x: 0, y: quarterH + 1, w: halfW, h: quarterH - 2), 0,
            "the second-row-left eighth is empty")
        XCTAssertEqual(
            image.countDiffering(from: bg, x: 0, y: 0, w: h.cellWidth, h: quarterH - 1), 0,
            "ink in the first row")
        XCTAssertEqual(
            image.countDiffering(
                from: bg, x: halfW + 1, y: 0, w: h.cellWidth - halfW - 1, h: h.cellHeight),
            0, "ink in the right half")
    }

    /// A separated quadrant leaves a gap all the way round, unlike the plain
    /// quadrant blocks.
    func testSeparatedQuadrantHasGaps() throws {
        let h = try RenderHarness(columns: 1, rows: 1, pointSize: 26)
        h.source.write("\u{1CC21}", row: 0)  // top-left separated quadrant
        let image = try h.render()
        let bg = ColorMath.expected(h.source.snapshot.background)

        // Nothing touches any edge of the cell.
        XCTAssertEqual(
            image.countDiffering(from: bg, x: 0, y: 0, w: h.cellWidth, h: 1), 0,
            "ink on the top edge")
        XCTAssertEqual(
            image.countDiffering(from: bg, x: 0, y: 0, w: 1, h: h.cellHeight), 0,
            "ink on the left edge")
        // But there is something in the top-left quadrant.
        XCTAssertGreaterThan(
            image.countDiffering(
                from: bg, x: 0, y: 0, w: h.cellWidth / 2, h: h.cellHeight / 2),
            0, "the quadrant is empty")
    }
}
