//  EngineRenderTests.swift
//  The real terminal, rendered.
//
//  The other tests build a `TerminalSnapshot` by hand, which exercises the
//  renderer but not the ~200 lines of FFI that pull one out of libghostty.
//  These drive a real `TerminalEngine`: VT bytes in, pixels out, which is
//  exactly what the app does.

import GhosttyVt
import XCTest

final class EngineRenderTests: XCTestCase {
    private func harness(
        columns: UInt16, rows: UInt16
    ) throws -> (
        RenderHarness, TerminalEngine
    ) {
        let engine = try TerminalEngine(cols: columns, rows: rows)
        let h = try RenderHarness(
            columns: Int(columns), rows: Int(rows), source: engine)
        return (h, engine)
    }

    private func write(_ engine: TerminalEngine, _ text: String) {
        var bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            engine.write(UnsafeRawBufferPointer(buf))
        }
    }

    /// Plain text goes through the VT parser, the render state, the snapshot
    /// extraction, shaping and the GPU, and comes out in the right cells.
    func testPlainTextReachesTheScreen() throws {
        let (h, engine) = try harness(columns: 20, rows: 4)
        write(engine, "hello")

        let image = try h.render()
        let bg = ColorMath.expected(h.renderer.snapshot.background)

        for column in 0..<5 {
            let r = h.cellRect(column: column, row: 0)
            XCTAssertGreaterThan(
                image.countDiffering(from: bg, x: r.x, y: r.y, w: r.w, h: r.h), 0,
                "no ink in column \(column)")
        }
        // Nothing past the text.
        let after = h.cellRect(column: 6, row: 0)
        XCTAssertEqual(
            image.countDiffering(from: bg, x: after.x, y: after.y, w: after.w, h: after.h), 0)
    }

    /// SGR colours survive the round trip. 48;2 sets a true-colour
    /// background, which exercises the resolved-colour path in extraction.
    func testTrueColourBackground() throws {
        let (h, engine) = try harness(columns: 10, rows: 2)
        write(engine, "\u{1b}[48;2;200;30;40m \u{1b}[0m")

        let image = try h.render()
        let r = h.cellRect(column: 0, row: 0)
        let expected = ColorMath.expected(PackedRGB(r: 200, g: 30, b: 40))
        assertColor(image.pixel(x: r.x + 1, y: r.y + 1), expected, tolerance: 2)
    }

    /// A palette background resolves through the terminal's palette rather
    /// than being passed through as an index.
    func testPaletteBackground() throws {
        let (h, engine) = try harness(columns: 10, rows: 2)
        // SGR 41 is palette colour 1, red.
        write(engine, "\u{1b}[41m \u{1b}[0m")

        let image = try h.render()
        let r = h.cellRect(column: 0, row: 0)
        let bg = ColorMath.expected(h.renderer.snapshot.background)
        let p = image.pixel(x: r.x + 1, y: r.y + 1)
        XCTAssertGreaterThan(
            abs(Int(p.r) - Int(bg.r)) + abs(Int(p.g) - Int(bg.g)) + abs(Int(p.b) - Int(bg.b)),
            10, "palette background was not applied")
        // Red should dominate.
        XCTAssertGreaterThan(Int(p.r), Int(p.g))
        XCTAssertGreaterThan(Int(p.r), Int(p.b))
    }

    /// Newlines move the cursor down, so the second line lands on row 1.
    func testNewlinePutsTextOnTheNextRow() throws {
        let (h, engine) = try harness(columns: 10, rows: 4)
        write(engine, "ab\r\ncd")

        let image = try h.render()
        let bg = ColorMath.expected(h.renderer.snapshot.background)

        for row in 0..<2 {
            let r = h.cellRect(column: 0, row: row)
            XCTAssertGreaterThan(
                image.countDiffering(from: bg, x: r.x, y: r.y, w: r.w * 2, h: r.h), 0,
                "row \(row) is empty")
        }
        XCTAssertEqual(
            image.countDiffering(
                from: bg, x: 0, y: 2 * h.cellHeight, w: image.width, h: h.cellHeight),
            0, "row 2 should be empty")
    }

    /// The cursor follows the text, and lands after the last character.
    func testCursorFollowsOutput() throws {
        let (h, engine) = try harness(columns: 10, rows: 2)
        write(engine, "abc")
        _ = try h.render()

        XCTAssertTrue(h.renderer.snapshot.cursor.hasViewport)
        XCTAssertEqual(h.renderer.snapshot.cursor.x, 3)
        XCTAssertEqual(h.renderer.snapshot.cursor.y, 0)
    }

    /// A wide character occupies two cells and its spacer draws nothing of
    /// its own.
    func testWideCharacterOccupiesTwoCells() throws {
        let (h, engine) = try harness(columns: 10, rows: 2)
        write(engine, "水")
        _ = try h.render()

        XCTAssertEqual(h.renderer.snapshotCell(0, 0)?.wide, .wide)
        XCTAssertEqual(h.renderer.snapshotCell(1, 0)?.wide, .spacerTail)
        // The cursor sits after both cells.
        XCTAssertEqual(h.renderer.snapshot.cursor.x, 2)
    }

    /// A combining mark stays attached to its base character, in one cell.
    func testCombiningMarkStaysInOneCell() throws {
        let (h, engine) = try harness(columns: 10, rows: 2)
        write(engine, "e\u{0301}")  // e + combining acute
        _ = try h.render()

        let cell = h.renderer.snapshotCell(0, 0)
        XCTAssertEqual(cell?.codepoint, UInt32(UInt8(ascii: "e")))
        XCTAssertEqual(cell?.graphemeLen, 1, "the combining mark was not attached")
        XCTAssertEqual(h.renderer.snapshot.cursor.x, 1)
    }

    /// SGR attributes reach the renderer as flags.
    func testStyleFlagsSurvive() throws {
        let (h, engine) = try harness(columns: 10, rows: 2)
        write(engine, "\u{1b}[1;3;4;9mx\u{1b}[0m")  // bold italic underline strike
        _ = try h.render()

        let cell = try XCTUnwrap(h.renderer.snapshotCell(0, 0))
        XCTAssertTrue(cell.flags.contains(.bold))
        XCTAssertTrue(cell.flags.contains(.italic))
        XCTAssertTrue(cell.flags.contains(.strikethrough))
        XCTAssertEqual(cell.underline, .single)
    }

    /// Writing to one line marks only that line dirty, so the renderer does
    /// the work the dirty tracking promises.
    func testOnlyChangedRowsAreDirty() throws {
        let (h, engine) = try harness(columns: 20, rows: 6)
        write(engine, "one\r\ntwo\r\nthree")
        _ = try h.render()

        write(engine, "!")
        _ = try h.render()

        let dirty = h.renderer.snapshot.rowDirty
        XCTAssertEqual(dirty.filter { $0 }.count, 1, "expected exactly one dirty row")
        XCTAssertTrue(dirty[2], "the edited row should be the dirty one")
    }

    /// Erasing the screen is a full repaint, and leaves nothing behind.
    func testEraseClearsEverything() throws {
        let (h, engine) = try harness(columns: 12, rows: 3)
        write(engine, "filled with text")
        let before = try h.render()

        write(engine, "\u{1b}[2J\u{1b}[H")
        let after = try h.render()

        let bg = ColorMath.expected(h.renderer.snapshot.background)
        XCTAssertGreaterThan(
            before.countDiffering(from: bg, x: 0, y: 0, w: before.width, h: before.height), 0)
        // Only the cursor should remain.
        let cursorCell = h.cellRect(column: 0, row: 0)
        var ink = after.countDiffering(from: bg, x: 0, y: 0, w: after.width, h: after.height)
        ink -= after.countDiffering(
            from: bg, x: cursorCell.x, y: cursorCell.y, w: cursorCell.w, h: cursorCell.h)
        XCTAssertEqual(ink, 0, "the screen was not cleared")
    }
}
