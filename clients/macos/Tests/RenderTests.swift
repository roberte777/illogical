//  RenderTests.swift
//  End-to-end checks that the right pixels land in the right cells.

import XCTest

final class RenderTests: XCTestCase {
    /// An empty screen is the background colour, everywhere, and it is the
    /// colour the shader's sRGB-to-P3 conversion should have produced.
    func testBlankScreenIsBackgroundColour() throws {
        let h = try RenderHarness(columns: 10, rows: 4)
        let image = try h.render()

        XCTAssertEqual(image.width, 10 * h.cellWidth)
        XCTAssertEqual(image.height, 4 * h.cellHeight)
        XCTAssertTrue(image.isUniform(x: 0, y: 0, w: image.width, h: image.height))

        let expected = ColorMath.expected(h.source.snapshot.background)
        let actual = image.pixel(x: 1, y: 1)
        assertColor(actual, expected, tolerance: 2)
    }

    /// A cell with its own background colour paints exactly its own cell.
    func testCellBackgroundFillsExactlyOneCell() throws {
        let h = try RenderHarness(columns: 6, rows: 3)
        let red = PackedRGB(r: 200, g: 30, b: 30)
        h.source.setBackground(red, row: 1, column: 2)

        let image = try h.render()

        let cell = h.cellRect(column: 2, row: 1)
        XCTAssertTrue(image.isUniform(x: cell.x, y: cell.y, w: cell.w, h: cell.h))

        let expected = ColorMath.expected(red)
        let actual = image.pixel(x: cell.x + 1, y: cell.y + 1)
        assertColor(actual, expected, tolerance: 2)

        // The neighbours are untouched.
        let bg = ColorMath.expected(h.source.snapshot.background)
        let left = h.cellRect(column: 1, row: 1)
        XCTAssertEqual(
            image.countDiffering(from: bg, x: left.x, y: left.y, w: left.w, h: left.h), 0)
        let above = h.cellRect(column: 2, row: 0)
        XCTAssertEqual(
            image.countDiffering(from: bg, x: above.x, y: above.y, w: above.w, h: above.h), 0)
    }

    /// Text draws ink in the cells that have text and nowhere else.
    func testTextDrawsInItsOwnCells() throws {
        let h = try RenderHarness(columns: 12, rows: 3)
        h.source.write("Hi", row: 1, column: 3)

        let image = try h.render()
        let bg = ColorMath.expected(h.source.snapshot.background)

        for column in [3, 4] {
            let r = h.cellRect(column: column, row: 1)
            let ink = image.countDiffering(from: bg, x: r.x, y: r.y, w: r.w, h: r.h)
            XCTAssertGreaterThan(ink, 0, "expected ink in column \(column)")
        }

        // Everything else is untouched background.
        for column in [0, 1, 2, 5, 6] {
            let r = h.cellRect(column: column, row: 1)
            XCTAssertEqual(
                image.countDiffering(from: bg, x: r.x, y: r.y, w: r.w, h: r.h), 0,
                "unexpected ink in column \(column)")
        }
        for row in [0, 2] {
            XCTAssertEqual(
                image.countDiffering(
                    from: bg, x: 0, y: row * h.cellHeight, w: image.width, h: h.cellHeight),
                0, "unexpected ink in row \(row)")
        }
    }

    /// FULL BLOCK must cover its whole cell. If it doesn't, blocks tiled
    /// across a row show seams, which is the single most visible sprite bug.
    func testFullBlockCoversWholeCell() throws {
        let h = try RenderHarness(columns: 4, rows: 2)
        h.source.write("\u{2588}", row: 0, column: 1)

        let image = try h.render()
        let r = h.cellRect(column: 1, row: 0)
        XCTAssertTrue(
            image.isUniform(x: r.x, y: r.y, w: r.w, h: r.h),
            "FULL BLOCK left gaps in its cell")

        // And it should be the foreground colour, since a covering glyph is
        // drawn as a background fill.
        let expected = ColorMath.expected(h.source.snapshot.foreground)
        let actual = image.pixel(x: r.x + r.w / 2, y: r.y + r.h / 2)
        assertColor(actual, expected, tolerance: 3)
    }

    /// A horizontal box drawing line must reach both edges of its cell, or
    /// adjacent cells won't join.
    func testBoxDrawingLineSpansFullWidth() throws {
        let h = try RenderHarness(columns: 4, rows: 2)
        h.source.write("\u{2500}\u{2500}", row: 0, column: 1)  // ──

        let image = try h.render()
        let bg = ColorMath.expected(h.source.snapshot.background)

        // Find the row of pixels the line sits on.
        let r = h.cellRect(column: 1, row: 0)
        var lineY: Int? = nil
        for y in r.y..<(r.y + r.h)
        where image.countDiffering(from: bg, x: r.x, y: y, w: 1, h: 1) > 0 {
            lineY = y
            break
        }
        let y = try XCTUnwrap(lineY, "no horizontal line drawn")

        // Every pixel across both cells is ink: no gap at the join.
        let span = h.cellRect(column: 1, row: 0).w * 2
        XCTAssertEqual(
            image.countDiffering(from: bg, x: r.x, y: y, w: span, h: 1), span,
            "box drawing line has a gap")
    }

    /// The cursor draws where the cursor is.
    func testBlockCursorDrawsAtCursorCell() throws {
        let h = try RenderHarness(columns: 6, rows: 3)
        h.source.snapshot.cursor = SnapshotCursor(
            hasViewport: true, x: 2, y: 1, wideTail: false, visible: true,
            blinking: false, passwordInput: false, style: .block)

        let image = try h.render()
        let bg = ColorMath.expected(h.source.snapshot.background)

        let cell = h.cellRect(column: 2, row: 1)
        XCTAssertTrue(
            image.isUniform(x: cell.x, y: cell.y, w: cell.w, h: cell.h),
            "block cursor did not fill its cell")
        XCTAssertGreaterThan(
            image.countDiffering(from: bg, x: cell.x, y: cell.y, w: cell.w, h: cell.h), 0)

        let neighbour = h.cellRect(column: 3, row: 1)
        XCTAssertEqual(
            image.countDiffering(
                from: bg, x: neighbour.x, y: neighbour.y, w: neighbour.w, h: neighbour.h),
            0, "cursor bled into the next cell")
    }

    /// Text under a block cursor is redrawn in the background colour, so it
    /// reads as a knockout rather than disappearing.
    func testTextUnderBlockCursorIsKnockedOut() throws {
        let h = try RenderHarness(columns: 6, rows: 2)
        h.source.write("W", row: 0, column: 1)
        h.source.snapshot.cursor = SnapshotCursor(
            hasViewport: true, x: 1, y: 0, wideTail: false, visible: true,
            blinking: false, passwordInput: false, style: .block)

        let image = try h.render()
        let cell = h.cellRect(column: 1, row: 0)

        // The cell is cursor-coloured with the glyph punched out of it, so it
        // is neither uniform nor background-coloured.
        XCTAssertFalse(
            image.isUniform(x: cell.x, y: cell.y, w: cell.w, h: cell.h),
            "expected the glyph to show through the cursor")

        let bg = ColorMath.expected(h.source.snapshot.background)
        let backgroundPixels =
            cell.w * cell.h
            - image.countDiffering(from: bg, x: cell.x, y: cell.y, w: cell.w, h: cell.h)
        XCTAssertGreaterThan(
            backgroundPixels, 0, "the glyph should be drawn in the background colour")
    }

    /// Underlines are drawn, and in the lower part of the cell.
    func testUnderlineDrawsBelowTheGlyph() throws {
        let h = try RenderHarness(columns: 4, rows: 2)
        var cell = RenderCell()
        cell.codepoint = UInt32(UInt8(ascii: "x"))
        cell.hasText = true
        cell.hasStyling = true
        cell.underline = .single
        h.source.snapshot.rowData[0].cells[1] = cell

        let image = try h.render()
        let bg = ColorMath.expected(h.source.snapshot.background)
        let r = h.cellRect(column: 1, row: 0)

        // The lowest row of ink should be well below the middle of the cell.
        var lowest = -1
        for y in r.y..<(r.y + r.h)
        where image.countDiffering(from: bg, x: r.x, y: y, w: r.w, h: 1) > 0 {
            lowest = y
        }
        XCTAssertGreaterThan(lowest, r.y + r.h / 2, "no underline near the baseline")
    }

    /// Only dirty rows are rebuilt, and clean rows keep what they had.
    ///
    /// This is the property the whole two-layer dirty scheme exists for, and
    /// it is easy to break by clearing too much.
    func testPartialUpdateLeavesCleanRowsIntact() throws {
        let h = try RenderHarness(columns: 8, rows: 3)
        h.source.write("aaaa", row: 0)
        h.source.write("bbbb", row: 1)
        let first = try h.render()

        // Now change row 1 only, and say so.
        h.source.snapshot.dirty = .partial
        h.source.snapshot.rowData[1].reset(columns: 8)
        h.source.write("cc", row: 1)
        h.source.clearRowDirtyExcept(1)

        let second = try h.render()

        // Row 0 is byte-identical.
        let rowBytes = h.cellHeight * first.width * 4
        XCTAssertEqual(
            Array(first.pixels[0..<rowBytes]), Array(second.pixels[0..<rowBytes]),
            "a clean row changed")

        // Row 1 did change.
        XCTAssertNotEqual(
            Array(first.pixels[rowBytes..<(rowBytes * 2)]),
            Array(second.pixels[rowBytes..<(rowBytes * 2)]),
            "the dirty row did not change")
    }

    /// Inverse video swaps foreground and background.
    func testInverseSwapsColours() throws {
        let h = try RenderHarness(columns: 4, rows: 1)
        h.source.write(" ", row: 0, column: 1, flags: [.inverse])

        let image = try h.render()
        let r = h.cellRect(column: 1, row: 0)
        let expected = ColorMath.expected(h.source.snapshot.foreground)
        let actual = image.pixel(x: r.x + 1, y: r.y + 1)
        assertColor(actual, expected, tolerance: 2)
    }
}

/// Compare a rendered pixel to an expected colour, allowing for the rounding
/// the GPU does when it encodes the result.
func assertColor(
    _ actual: (b: UInt8, g: UInt8, r: UInt8, a: UInt8),
    _ expected: (b: UInt8, g: UInt8, r: UInt8, a: UInt8),
    tolerance: Int,
    file: StaticString = #filePath, line: UInt = #line
) {
    let dr = abs(Int(actual.r) - Int(expected.r))
    let dg = abs(Int(actual.g) - Int(expected.g))
    let db = abs(Int(actual.b) - Int(expected.b))
    XCTAssertLessThanOrEqual(
        max(dr, dg, db), tolerance,
        "rgb(\(actual.r), \(actual.g), \(actual.b)) != rgb(\(expected.r), \(expected.g), \(expected.b))",
        file: file, line: line)
}

extension FakeSource {
    /// Mark every row clean except one, as a partial update would.
    func clearRowDirtyExcept(_ row: Int) {
        for i in snapshot.rowDirty.indices { snapshot.rowDirty[i] = (i == row) }
    }
}
