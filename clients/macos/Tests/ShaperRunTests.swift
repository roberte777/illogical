//  ShaperRunTests.swift
//  Where the shaper splits a row into runs.
//
//  Run boundaries decide two things at once: which glyphs the font is allowed
//  to join into a ligature, and which cells share a colour. Both failure
//  modes are quiet — a ligature that shouldn't exist, or a character drawn in
//  its neighbour's colour — so the boundaries are worth asserting directly
//  rather than inferring from pixels.

import XCTest

final class ShaperRunTests: XCTestCase {
    private func row(_ text: String, columns: Int = 16) -> [RenderCell] {
        var cells = [RenderCell](repeating: RenderCell(), count: columns)
        for (i, scalar) in text.unicodeScalars.enumerated() where i < columns {
            cells[i].codepoint = scalar.value
            cells[i].hasText = true
        }
        return cells
    }

    private func shaper() -> TextShaper {
        TextShaper(grid: FontGridSet.grid(family: "Menlo", pointSize: 13, scale: 2))
    }

    /// Boundaries between runs, as column indices.
    private func boundaries(_ runs: [TextRun]) -> [Int] {
        runs.map { Int($0.offset) }
    }

    func testPlainTextIsOneRun() {
        let runs = shaper().runs(
            row: row("hello"), graphemes: [], cols: 16, selection: nil, cursorX: nil)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].offset, 0)
        XCTAssertEqual(runs[0].count, 5)
    }

    /// fi, fl and st join into ligatures that are narrower than the two cells
    /// they span, so the run must break between them and stop the font.
    func testBadLigaturePairsSplitTheRun() {
        for pair in ["fi", "fl", "st"] {
            let runs = shaper().runs(
                row: row(pair), graphemes: [], cols: 16, selection: nil, cursorX: nil)
            XCTAssertEqual(
                runs.count, 2, "\(pair) should be two runs, got \(boundaries(runs))")
            XCTAssertEqual(runs.first?.offset, 0)
            XCTAssertEqual(runs.last?.offset, 1)
        }
    }

    /// Pairs that merely start with the same letter must not split — that
    /// would defeat ligatures generally.
    func testOtherPairsStayInOneRun() {
        for pair in ["fa", "fo", "sa", "ti", "il"] {
            let runs = shaper().runs(
                row: row(pair), graphemes: [], cols: 16, selection: nil, cursorX: nil)
            XCTAssertEqual(runs.count, 1, "\(pair) should be one run")
        }
    }

    /// A style change splits the run, so a two-character operator whose
    /// halves are coloured differently can't ligate into one colour.
    func testStyleChangeSplitsTheRun() {
        var cells = row(">=")
        cells[1].hasStyling = true
        cells[1].fg = PackedRGB(r: 255, g: 0, b: 0)

        let runs = shaper().runs(
            row: cells, graphemes: [], cols: 16, selection: nil, cursorX: nil)
        XCTAssertEqual(runs.count, 2, "a colour change should split the run")
    }

    /// Background colour alone must *not* split: the background is painted
    /// separately, so a run may span a change in it.
    func testBackgroundChangeDoesNotSplitTheRun() {
        var cells = row(">=")
        cells[1].hasStyling = true
        cells[1].bg = PackedRGB(r: 255, g: 0, b: 0)

        let runs = shaper().runs(
            row: cells, graphemes: [], cols: 16, selection: nil, cursorX: nil)
        XCTAssertEqual(runs.count, 1, "a background change should not split the run")
    }

    /// Bold splits, because it selects a different face.
    func testBoldSplitsTheRun() {
        var cells = row("ab")
        cells[1].hasStyling = true
        cells[1].flags = [.bold]

        let runs = shaper().runs(
            row: cells, graphemes: [], cols: 16, selection: nil, cursorX: nil)
        XCTAssertEqual(runs.count, 2)
    }

    /// The cursor cell is isolated, so the shader can recolour it without
    /// dragging its neighbours along.
    func testCursorSplitsTheRunAroundItself() {
        let runs = shaper().runs(
            row: row("abcde"), graphemes: [], cols: 16, selection: nil, cursorX: 2)
        XCTAssertEqual(
            boundaries(runs), [0, 2, 3],
            "expected before / exactly the cursor / after")
    }

    /// A selection edge splits, so the two sides get their own colours.
    func testSelectionEdgeSplitsTheRun() {
        let runs = shaper().runs(
            row: row("abcdef"), graphemes: [], cols: 16, selection: (start: 2, end: 3),
            cursorX: nil)
        XCTAssertEqual(boundaries(runs), [0, 2, 4])
    }

    /// Leading blanks are part of the run — they shape as spaces and share
    /// the font — exactly as in libghostty. Only the right side is trimmed.
    func testLeadingBlanksJoinTheRun() {
        var cells = [RenderCell](repeating: RenderCell(), count: 16)
        for (i, scalar) in "word".unicodeScalars.enumerated() {
            cells[i + 6].codepoint = scalar.value
            cells[i + 6].hasText = true
        }
        let runs = shaper().runs(
            row: cells, graphemes: [], cols: 16, selection: nil, cursorX: nil)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].offset, 0, "the run should start at the first blank")
        XCTAssertEqual(runs[0].count, 10, "six blanks plus four letters")
    }

    /// Runs hash on their contents with cluster positions taken relative to
    /// the run start, so the same run content at two different columns is one
    /// cache entry rather than two.
    func testIdenticalRunsAtDifferentColumnsShareAHash() {
        let s = shaper()
        let atZero = s.runs(
            row: row("word"), graphemes: [], cols: 16, selection: nil, cursorX: nil)
        XCTAssertEqual(atZero.count, 1)
        let hashAtZero = atZero[0].hash

        // Push the word along by preceding it with something that splits the
        // run, so the second run's content is identical but its offset isn't.
        var shifted = row("Xword")
        shifted[0].hasStyling = true
        shifted[0].flags = [.bold]

        let runs = s.runs(
            row: shifted, graphemes: [], cols: 16, selection: nil, cursorX: nil)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[1].offset, 1)
        XCTAssertEqual(runs[1].count, 4)
        XCTAssertEqual(runs[1].hash, hashAtZero, "the hash should be position-independent")
    }

    /// Different text must not collide, or the cache would serve the wrong
    /// glyphs.
    func testDifferentTextHashesDifferently() {
        let s = shaper()
        let a = s.runs(row: row("word"), graphemes: [], cols: 16, selection: nil, cursorX: nil)
        let ha = a[0].hash
        let b = s.runs(row: row("wore"), graphemes: [], cols: 16, selection: nil, cursorX: nil)
        XCTAssertNotEqual(b[0].hash, ha)
    }

    /// Trailing blanks shape to nothing, so a mostly-empty row costs almost
    /// nothing.
    func testTrailingBlanksAreNotShaped() {
        let runs = shaper().runs(
            row: row("hi", columns: 200), graphemes: [], cols: 200, selection: nil,
            cursorX: nil)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].count, 2, "shaped past the end of the text")
    }
}
