//  SearchTests.swift
//  Finding things, and getting out of the way of what was found.
//
//  Two halves, and they are deliberately different kinds of test.
//
//  The engine half drives `TerminalEngine`'s search API against a real
//  libghostty terminal — query in, counts and row-local spans out — so what is
//  under test is the whole path: needle to feed to tick to match to grid
//  reference to viewport cell. That last conversion is the only part of #16
//  the C API does not do for us, so it is the part worth pinning.
//
//  The nudge half is pure geometry with no terminal in it at all. "The find bar
//  moves out from over a match" is a claim about rectangles, and rectangles are
//  the one part of a floating overlay a test can hold without a window.

import CoreGraphics
import GhosttyVt
import XCTest

final class SearchTests: XCTestCase {
    private func engine(_ lines: [String] = []) throws -> TerminalEngine {
        let engine = try TerminalEngine(cols: 80, rows: 10)
        for line in lines { write(engine, line + "\r\n") }
        return engine
    }

    private func write(_ engine: TerminalEngine, _ text: String) {
        var bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { engine.write(UnsafeRawBufferPointer($0)) }
    }

    /// Run the search to completion, the way the find bar's loop does but
    /// without the waiting. Bounded: a query with nothing to find is complete
    /// on the first pump, and a stuck one fails the test rather than hanging.
    @discardableResult
    private func settle(_ engine: TerminalEngine) -> SearchProgress {
        for _ in 0..<64 {
            let progress = engine.pumpSearch()
            if progress.isComplete { return progress }
        }
        XCTFail("search never completed")
        return .idle
    }

    // MARK: - Finding

    func testFindsEveryMatchOnScreen() throws {
        let engine = try engine([
            "compiling module A... ok",
            "compiling module B... error: missing semicolon",
            "linking... error: undefined symbol",
        ])

        engine.setSearchQuery("error")
        let progress = settle(engine)

        XCTAssertEqual(progress.total, 2)
        XCTAssertTrue(progress.isComplete)
    }

    func testMatchingIsCaseInsensitiveForASCII() throws {
        let engine = try engine(["ERROR: one", "error: two", "Error: three"])

        engine.setSearchQuery("error")
        XCTAssertEqual(settle(engine).total, 3)
    }

    func testNoNeedleFindsNothing() throws {
        let engine = try engine(["error"])

        XCTAssertEqual(engine.searchProgress.total, 0)
        XCTAssertTrue(engine.searchViewportSpans().isEmpty)
    }

    /// Closing the find bar has to drop the results, not just hide them: a
    /// needle left in place goes on being rescanned at every feed.
    func testEndingTheSearchDropsTheMatches() throws {
        let engine = try engine(["error here"])
        engine.setSearchQuery("error")
        settle(engine)
        XCTAssertEqual(engine.searchProgress.total, 1)

        engine.endSearch()
        XCTAssertEqual(engine.searchProgress.total, 0)
        XCTAssertTrue(engine.searchViewportSpans().isEmpty)
    }

    // MARK: - Stepping

    func testNextSelectsAMatchAndPreviousComesBack() throws {
        let engine = try engine(["error one", "error two", "error three"])
        engine.setSearchQuery("error")
        settle(engine)

        XCTAssertNil(engine.searchProgress.selected)

        // Newest first, so index 0 is the *last* line to have been written.
        XCTAssertTrue(engine.selectNextMatch())
        XCTAssertEqual(engine.searchProgress.selected, 0)

        XCTAssertTrue(engine.selectNextMatch())
        XCTAssertEqual(engine.searchProgress.selected, 1)

        XCTAssertTrue(engine.selectPreviousMatch())
        XCTAssertEqual(engine.searchProgress.selected, 0)
    }

    func testSelectionWrapsPastTheOldestMatch() throws {
        let engine = try engine(["error one", "error two"])
        engine.setSearchQuery("error")
        settle(engine)

        engine.selectNextMatch()
        engine.selectNextMatch()
        XCTAssertEqual(engine.searchProgress.selected, 1)

        engine.selectNextMatch()
        XCTAssertEqual(engine.searchProgress.selected, 0, "the newest match, come round again")
    }

    // MARK: - Where the matches are

    /// The conversion #16 says is ours to write: a match is a selection over
    /// two grid references, and the renderer wants row-local cell ranges.
    func testViewportSpansLandOnTheRightCells() throws {
        let engine = try engine(["the error is here", "no hits on this line"])
        engine.setSearchQuery("error")
        settle(engine)

        let spans = engine.searchViewportSpans()
        XCTAssertEqual(spans.count, 1)
        // Row 0 is "the error is here"; "error" starts at column 4 and is five
        // cells wide, so it ends at 8 inclusive.
        XCTAssertEqual(spans.first?.row, 0)
        XCTAssertEqual(spans.first?.start, 4)
        XCTAssertEqual(spans.first?.end, 8)
    }

    func testOnlyTheSelectedMatchIsMarkedSelected() throws {
        let engine = try engine(["error one", "error two"])
        engine.setSearchQuery("error")
        settle(engine)
        engine.selectNextMatch()

        let spans = engine.searchViewportSpans()
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans.filter(\.isSelected).count, 1)
        // Newest first: the selected one is the second line, which is row 1.
        XCTAssertEqual(spans.first(where: \.isSelected)?.row, 1)
    }

    /// Matches scrolled off the top have no viewport coordinate, and
    /// libghostty's viewport list may still carry them because they share a
    /// page with the screen. They must not be drawn at a row that is on it.
    func testMatchesAboveTheViewportAreNotDrawn() throws {
        let engine = try engine()
        write(engine, "error at the top\r\n")
        for i in 0..<40 { write(engine, "filler line \(i)\r\n") }

        engine.setSearchQuery("error")
        settle(engine)

        XCTAssertEqual(engine.searchProgress.total, 1, "still found, in the scrollback")
        XCTAssertTrue(engine.searchViewportSpans().isEmpty, "but nothing to paint")
    }

    /// The search follows the terminal: output that arrives after the query is
    /// set is searched too, without the query being resubmitted.
    func testNewOutputIsSearched() throws {
        let engine = try engine(["error one"])
        engine.setSearchQuery("error")
        settle(engine)
        XCTAssertEqual(engine.searchProgress.total, 1)

        write(engine, "error two\r\n")
        XCTAssertEqual(settle(engine).total, 2)
    }

    /// A snapshot arriving under an open find bar replaces the terminal, and a
    /// search cannot be rebound — so the engine makes a new one and gives it
    /// the same needle. Without that the bar would sit there reporting nothing.
    func testSearchSurvivesAdoptingANewTerminal() throws {
        let engine = try engine(["error one"])
        engine.setSearchQuery("error")
        settle(engine)

        var replacement: GhosttyTerminal?
        XCTAssertEqual(ghostty_terminal_new(nil, &replacement, 80, 10), GHOSTTY_SUCCESS)
        let terminal = try XCTUnwrap(replacement)
        let text = "error after the attach\r\n"
        var bytes = Array(text.utf8)
        bytes.withUnsafeMutableBufferPointer {
            ghostty_terminal_vt_write(terminal, $0.baseAddress, $0.count)
        }
        engine.adopt(terminal: terminal)

        XCTAssertEqual(settle(engine).total, 1)
        XCTAssertEqual(engine.searchViewportSpans().first?.row, 0)
    }

    // MARK: - Painting

    func testTheSelectedMatchOutranksAPlainOneAndASelection() {
        var row = RenderRow()
        row.reset(columns: 10)
        row.selection = (start: 0, end: 9)
        row.search = [
            SearchHighlight(start: 2, end: 3, isSelected: false),
            SearchHighlight(start: 5, end: 6, isSelected: true),
        ]

        XCTAssertEqual(row.paint(at: 0), .selection)
        XCTAssertEqual(row.paint(at: 2), .searchMatch)
        XCTAssertEqual(row.paint(at: 5), .searchSelected)
        XCTAssertEqual(row.paint(at: 9), .selection)
    }

    /// A spacer tail is the second half of a wide character and belongs to the
    /// cell before it, or the back half of a match would go unpainted.
    func testASpacerTailTakesItsHeadsHighlight() {
        var row = RenderRow()
        row.reset(columns: 4)
        row.cells[0].wide = .wide
        row.cells[1].wide = .spacerTail
        row.search = [SearchHighlight(start: 0, end: 0, isSelected: false)]

        XCTAssertEqual(row.paint(at: 0), .searchMatch)
        XCTAssertEqual(row.paint(at: 1), .searchMatch)
        XCTAssertEqual(row.paint(at: 2), .plain)
    }

    // MARK: - Painted, for real

    /// The whole of #16 end to end: VT bytes into a real terminal, a query into
    /// a real search, and pixels out of the real renderer. A match gets the
    /// search background, the one you are standing on gets the other one, and
    /// the text either side of them is left alone.
    func testMatchesAreDrawnInTheirOwnColours() throws {
        let engine = try TerminalEngine(cols: 24, rows: 4)
        let harness = try RenderHarness(columns: 24, rows: 4, source: engine)
        write(engine, "an error here\r\nand error there\r\n")

        engine.setSearchQuery("error")
        settle(engine)
        engine.selectNextMatch()

        let image = try harness.render()
        let config = RendererConfig()
        let match = ColorMath.expected(
            PackedRGB(
                r: config.searchBackground.r, g: config.searchBackground.g,
                b: config.searchBackground.b))
        let selected = ColorMath.expected(
            PackedRGB(
                r: config.searchSelectedBackground.r, g: config.searchSelectedBackground.g,
                b: config.searchSelectedBackground.b))

        /// How much of a cell is painted `colour`. A cell holding a letter is
        /// mostly background, so "most of it" is the honest assertion — an
        /// exact count would be a claim about the font.
        func fraction(
            of colour: (b: UInt8, g: UInt8, r: UInt8, a: UInt8), column: Int, row: Int
        ) -> Double {
            let r = harness.cellRect(column: column, row: row)
            let differing = image.countDiffering(
                from: colour, x: r.x, y: r.y, w: r.w, h: r.h, tolerance: 4)
            return 1 - Double(differing) / Double(r.w * r.h)
        }

        // "an error here": the match is columns 3...7. Selection starts at the
        // newest match, which is the second line, so this one is a plain match.
        XCTAssertGreaterThan(fraction(of: match, column: 3, row: 0), 0.5)
        XCTAssertGreaterThan(fraction(of: match, column: 7, row: 0), 0.5)
        // Either side of it is ordinary terminal background.
        XCTAssertLessThan(fraction(of: match, column: 2, row: 0), 0.1)
        XCTAssertLessThan(fraction(of: match, column: 8, row: 0), 0.1)

        // "and error there": the selected match, in the brighter colour.
        XCTAssertGreaterThan(fraction(of: selected, column: 4, row: 1), 0.5)
        XCTAssertLessThan(
            fraction(of: selected, column: 3, row: 0), 0.1,
            "the unselected match must not be painted as the selected one")
    }

    // MARK: - Getting out of the way

    /// The bar as it sits in a 900x500 surface: `SearchBar.Metrics` at the
    /// default 17 pt row, 10 in from the top and the trailing edge.
    private let bar = CGRect(x: 450, y: 10, width: 446, height: 41)

    /// The bar is measured in terminal rows, not points, so that it keeps the
    /// reference's proportions when the font size changes — which the font
    /// work landing alongside this makes a live question rather than a
    /// hypothetical one.
    func testTheBarIsSizedInTerminalRows() {
        let m = SearchBar.Metrics.self
        // 2.43 rows tall, and 10.8 times as wide as it is tall, as measured off
        // the reference: 56 px against a 23 px row pitch.
        XCTAssertEqual(m.height(rowHeight: 17), 41)
        XCTAssertEqual(m.width(rowHeight: 17), 443)

        // The ratio is what is fixed, at every size a terminal font reaches.
        for row in stride(from: 10.0, through: 40.0, by: 1) {
            XCTAssertEqual(
                m.height(rowHeight: row) / row, m.rowsTall, accuracy: 0.05,
                "bar is not 2.43 rows at a \(row) pt row")
        }
    }
    private let limit: CGFloat = 225

    private func match(row: Int, x: CGFloat, width: CGFloat = 60) -> CGRect {
        CGRect(x: x, y: CGFloat(row) * 20, width: width, height: 20)
    }

    func testNothingSelectedMeansNoNudge() {
        XCTAssertEqual(SearchNudge.offset(bar: bar, match: nil, limit: limit), 0)
    }

    func testAMatchOnTheOtherSideOfTheScreenIsNotInTheWay() {
        // The bar's own rows, but at the left margin.
        XCTAssertEqual(
            SearchNudge.offset(bar: bar, match: match(row: 0, x: 0), limit: limit), 0)
    }

    func testTheBarStepsBelowTheMatchItWouldCover() {
        // Row 1 is y 20...40, and the bar's home is y 10...40.
        let selected = match(row: 1, x: 700)
        let offset = SearchNudge.offset(bar: bar, match: selected, limit: limit)

        XCTAssertGreaterThan(offset, 0)
        XCTAssertFalse(bar.offsetBy(dx: 0, dy: offset).intersects(selected))
        // Cleared the match's bottom edge with the gap, and no further.
        XCTAssertEqual(offset, 40 + SearchNudge.gap - bar.minY)
    }

    /// The behaviour this exists to have: a screenful of hits down the
    /// right-hand side moves the bar past *one* of them. Dodging all of them
    /// walked it halfway down the window to keep clear of matches nobody was
    /// looking at.
    func testOnlyTheSelectedMatchMovesIt() {
        let selected = match(row: 1, x: 700)
        let offset = SearchNudge.offset(bar: bar, match: selected, limit: limit)

        // Rows 2 and 3 are also hits and also under the bar's home, and the
        // bar comes to rest over them without a second thought.
        let moved = bar.offsetBy(dx: 0, dy: offset)
        XCTAssertTrue(moved.intersects(match(row: 2, x: 700)))
        XCTAssertFalse(moved.intersects(selected))
    }

    /// A needle long enough to wrap across many rows makes a match taller than
    /// the room there is to dodge into. A find bar halfway down the window is
    /// worse than one overlapping a match that already covers half the screen.
    func testAMatchItCannotClearLeavesItWhereItIs() {
        let tall = CGRect(x: 700, y: 0, width: 60, height: 400)
        XCTAssertEqual(SearchNudge.offset(bar: bar, match: tall, limit: limit), 0)
    }

    func testItNeverLeavesTheTopOfTheWindow() {
        for row in 0..<8 {
            let offset = SearchNudge.offset(bar: bar, match: match(row: row, x: 700), limit: limit)
            XCTAssertGreaterThanOrEqual(offset, 0)
            XCTAssertLessThanOrEqual(bar.minY + offset + bar.height, limit)
        }
    }
}
