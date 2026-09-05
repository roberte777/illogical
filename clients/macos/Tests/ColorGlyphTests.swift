//  ColorGlyphTests.swift
//  Emoji, which take a completely different path to the screen.
//
//  A colour glyph is rasterized premultiplied BGRA into a second atlas, is
//  sampled by a different branch of the fragment shader, and is scaled by a
//  constraint the grid applies rather than the renderer. None of that is
//  touched by monochrome text, so it needs its own coverage.

import XCTest

final class ColorGlyphTests: XCTestCase {
    /// The system's emoji font is found by fallback, and the glyph is
    /// classified as colour.
    func testEmojiResolvesToAColourFace() throws {
        let grid = FontGridSet.grid(family: "Menlo", pointSize: 13, scale: 2)
        let index = try XCTUnwrap(
            grid.index(codepoint: 0x1F44B, style: .regular, presentation: nil),
            "no face for U+1F44B")
        XCTAssertFalse(index.isSprite)

        let face = try XCTUnwrap(grid.lock.withRead { grid.face(index) })
        XCTAssertTrue(face.hasColor, "the fallback face for an emoji should have colour")

        let glyphIndex = try XCTUnwrap(face.glyphIndex(0x1F44B))
        let render = try grid.renderGlyph(
            index, glyph: glyphIndex, options: GlyphRenderOptions(cellWidth: 2))
        XCTAssertEqual(render.presentation, .emoji)
        XCTAssertFalse(render.glyph.isEmpty)
    }

    /// An emoji actually reaches the screen in colour: it is neither the
    /// background nor a monochrome smear of the foreground.
    func testEmojiRendersInColour() throws {
        let h = try RenderHarness(columns: 6, rows: 1, pointSize: 26)

        // Wide, as a terminal would place it, with its spacer tail.
        var cell = RenderCell()
        cell.codepoint = 0x1F44B  // 👋
        cell.hasText = true
        cell.wide = .wide
        h.source.snapshot.rowData[0].cells[1] = cell
        var tail = RenderCell()
        tail.wide = .spacerTail
        h.source.snapshot.rowData[0].cells[2] = tail

        let image = try h.render()
        image.dump(named: "emoji")

        let bg = ColorMath.expected(h.source.snapshot.background)
        // Sample the two cells the emoji spans.
        var sawColour = false
        var ink = 0
        for x in (1 * h.cellWidth)..<(3 * h.cellWidth) {
            for y in 0..<h.cellHeight {
                let p = image.pixel(x: x, y: y)
                let d =
                    abs(Int(p.r) - Int(bg.r)) + abs(Int(p.g) - Int(bg.g))
                    + abs(Int(p.b) - Int(bg.b))
                if d <= 2 { continue }
                ink += 1
                // Colour means the channels disagree; monochrome text drawn
                // in the foreground colour would keep them in proportion.
                let spread = max(Int(p.r), Int(p.g), Int(p.b)) - min(Int(p.r), Int(p.g), Int(p.b))
                if spread > 40 { sawColour = true }
            }
        }

        XCTAssertGreaterThan(ink, 20, "the emoji drew almost nothing")
        XCTAssertTrue(sawColour, "the emoji rendered without colour")

        // And it stayed inside its two cells.
        XCTAssertEqual(
            image.countDiffering(from: bg, x: 0, y: 0, w: h.cellWidth, h: h.cellHeight), 0,
            "the emoji bled into the cell before it")
        XCTAssertEqual(
            image.countDiffering(
                from: bg, x: 3 * h.cellWidth, y: 0, w: h.cellWidth, h: h.cellHeight), 0,
            "the emoji bled into the cell after it")
    }

    /// A CJK ideograph is wide but monochrome, and must come from the
    /// grayscale atlas so it picks up the cell's foreground colour.
    func testWideCJKIsMonochrome() throws {
        let grid = FontGridSet.grid(family: "Menlo", pointSize: 13, scale: 2)
        let index = try XCTUnwrap(
            grid.index(codepoint: 0x6C34, style: .regular, presentation: nil))
        let face = try XCTUnwrap(grid.lock.withRead { grid.face(index) })
        let glyphIndex = try XCTUnwrap(face.glyphIndex(0x6C34))
        let render = try grid.renderGlyph(
            index, glyph: glyphIndex, options: GlyphRenderOptions(cellWidth: 2))
        XCTAssertEqual(render.presentation, .text)
    }

    /// A variation selector asking for text presentation must not pull in a
    /// colour font.
    func testTextPresentationAvoidsColourFace() throws {
        let grid = FontGridSet.grid(family: "Menlo", pointSize: 13, scale: 2)
        // U+2714 HEAVY CHECK MARK has both presentations.
        guard
            let index = grid.index(codepoint: 0x2714, style: .regular, presentation: .text)
        else {
            throw XCTSkip("no face for U+2714")
        }
        if index.isSprite { return }
        let face = try XCTUnwrap(grid.lock.withRead { grid.face(index) })
        let glyphIndex = try XCTUnwrap(face.glyphIndex(0x2714))
        let render = try grid.renderGlyph(index, glyph: glyphIndex, options: .init())
        XCTAssertEqual(render.presentation, .text)
    }
}
