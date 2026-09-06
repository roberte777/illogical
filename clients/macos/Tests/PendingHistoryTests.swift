//  PendingHistoryTests.swift
//  The loading state: history the snapshot has declared and not yet sent.
//
//  Between the first frame and `history-restored` the client is painting a
//  terminal whose scrollback it does not have. The scrollbar used to describe
//  only what had arrived, so the scrollable area grew as pages landed and the
//  knob slid down the track under a user who had not touched the wheel.
//
//  What replaces that is a count of owed rows, declared at READY — the
//  snapshot knows the extent before it sends a byte of it — and counted down
//  as pages land. `ScrollbarState` reports the declared area, not the
//  delivered one, so `pending` falling and `offset` rising cancel exactly and
//  the knob stays put.
//
//  These are the arithmetic and lifetime of that count. Where it is *drawn* is
//  ScrollbarOverlayTests.

import GhosttyVt
import XCTest

final class PendingHistoryTests: XCTestCase {
    /// A terminal with `lines` written into it, and no scrollback limit, so
    /// the history is deep enough to arrive in more than one page.
    ///
    /// The limit matters more than the line count. `ghostty_terminal_new` asks
    /// for libghostty's default 10 KB, floored by `PageList` at two standard
    /// pages, and 40,000 lines under that floor yields exactly one history
    /// page — enough to prove a restore happens, not enough to watch a count
    /// come down over several. A NULL value removes the limit outright.
    private func makeTerminal(cols: UInt16, rows: UInt16, lines: Int) throws -> GhosttyTerminal {
        var handle: GhosttyTerminal?
        try check("ghostty_terminal_new") { ghostty_terminal_new(nil, &handle, cols, rows) }
        let terminal = try XCTUnwrap(handle)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)

        var text = ""
        for i in 0..<lines { text += "line \(i)\r\n" }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            ghostty_terminal_vt_write(terminal, buf.baseAddress, buf.count)
        }
        return terminal
    }

    private func encoded(_ terminal: GhosttyTerminal) throws -> Data {
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        try check("ghostty_snapshot_encode_alloc") {
            ghostty_snapshot_encode_alloc(terminal, nil, &ptr, &len)
        }
        let raw = try XCTUnwrap(ptr)
        defer { ghostty_free(nil, raw, len) }
        return Data(bytes: raw, count: len)
    }

    // MARK: - The count

    /// The declared extent counts every row above the active area, including
    /// the overlap READY already carried. Declaring it verbatim would draw
    /// rows we are looking at as pending, so what lands is the difference.
    func testDeclaringSubtractsWhatReadyAlreadyBrought() throws {
        let source = try makeTerminal(cols: 80, rows: 24, lines: 20_000)
        defer { ghostty_terminal_free(source) }
        let bytes = try encoded(source)

        let restore = try SnapshotRestore(snapshot: bytes)
        let terminal = try restore.ready()
        let engine = try TerminalEngine(cols: 80, rows: 24)
        engine.adopt(terminal: terminal, cols: 80, rows: 24)

        let resident = engine.scrollbar.total - engine.scrollbar.length
        let declared = restore.declaredHistoryRows
        XCTAssertGreaterThan(declared, 0, "a 20,000-line fixture declares history")
        XCTAssertGreaterThan(
            declared, resident, "READY cannot have carried the whole history")

        engine.declarePendingHistory(rows: declared)
        XCTAssertEqual(
            engine.scrollbar.pending, declared - resident,
            "only the rows that have not arrived are pending")
    }

    /// A snapshot that declares less than READY already delivered owes
    /// nothing. The extent is advisory, so this has to saturate rather than
    /// wrap a UInt64 into a scrollbar 18 quintillion rows tall.
    func testDeclaringLessThanIsResidentOwesNothing() throws {
        let engine = try TerminalEngine(cols: 80, rows: 24)
        engine.write(Data(Array("hello\r\n".utf8)))
        engine.declarePendingHistory(rows: 0)
        XCTAssertEqual(engine.scrollbar.pending, 0)
    }

    /// Pending rows extend the area at the top: the total grows by them, and
    /// so does every position inside it.
    func testPendingRowsExtendTheAreaAtTheTop() throws {
        let engine = try TerminalEngine(cols: 80, rows: 24)
        let before = engine.scrollbar
        engine.declarePendingHistory(rows: before.total - before.length + 500)

        let after = engine.scrollbar
        XCTAssertEqual(after.pending, 500)
        XCTAssertEqual(after.total, before.total + 500, "the area grew by what is owed")
        XCTAssertEqual(after.offset, before.offset + 500, "and the viewport moved down it")
        XCTAssertEqual(after.length, before.length, "the viewport is the same height")
        XCTAssertTrue(after.canScroll, "there is history above, it just has not arrived")
    }

    /// The headline: delivering history does not move the viewport's position
    /// on the bar. Every row that lands leaves `pending` and arrives in
    /// `offset`, so their sum — which is what positions the knob — holds still.
    func testDeliveringHistoryHoldsTheViewportPosition() throws {
        let source = try makeTerminal(cols: 80, rows: 24, lines: 20_000)
        defer { ghostty_terminal_free(source) }
        let bytes = try encoded(source)

        let restore = try SnapshotRestore(snapshot: bytes)
        let terminal = try restore.ready()
        let engine = try TerminalEngine(cols: 80, rows: 24)
        engine.adopt(terminal: terminal, cols: 80, rows: 24)
        engine.declarePendingHistory(rows: restore.declaredHistoryRows)
        XCTAssertGreaterThan(engine.scrollbar.pending, 0, "there is history to wait for")

        // Park inside the scrollback, 50 rows above the live output. Pinned to
        // the bottom the knob is at the bottom whatever happens above it, so
        // that case proves nothing; this is the one that used to slide.
        engine.scroll(.delta(-50))
        let parked = engine.scrollbar
        XCTAssertTrue(parked.isScrolledBack, "the viewport should be off the live output")

        var pages = 0
        while let rows = try restore.restoreNextHistoryPage() {
            engine.withLock { engine.historyPageRestoredLocked(rows: rows) }
            pages += 1
            XCTAssertLessThan(pages, 10_000, "history restore did not terminate")

            let now = engine.scrollbar
            XCTAssertEqual(
                now.total, parked.total,
                "the declared area is fixed; page \(pages) changed it")
            XCTAssertEqual(
                now.offset, parked.offset,
                "the viewport did not move; page \(pages) moved it on the bar")
        }
        XCTAssertGreaterThan(pages, 1, "fixture should restore over several pages")
        XCTAssertEqual(engine.scrollbar.pending, 0, "the pages delivered what was declared")
    }

    /// A viewport scrolled to the very top *does* travel as history lands, and
    /// the bar says so.
    ///
    /// Not a hole in the mechanism — libghostty's "top" is a position, not a
    /// pin. It means the oldest row there is, and it keeps meaning that as
    /// older rows arrive, so the viewport really is moving and a bar that held
    /// still would be the one lying. Worth a test because the arithmetic looks
    /// identical to the case above and the outcome is the opposite: `pending`
    /// falls while the terminal's own offset stays nailed to zero, so the sum
    /// falls with it.
    func testAViewportPinnedToTheTopTravelsWithTheArrivingHistory() throws {
        let source = try makeTerminal(cols: 80, rows: 24, lines: 20_000)
        defer { ghostty_terminal_free(source) }
        let bytes = try encoded(source)

        let restore = try SnapshotRestore(snapshot: bytes)
        let engine = try TerminalEngine(cols: 80, rows: 24)
        engine.adopt(terminal: try restore.ready(), cols: 80, rows: 24)
        engine.declarePendingHistory(rows: restore.declaredHistoryRows)

        engine.scroll(.top)
        let atTop = engine.scrollbar
        XCTAssertEqual(atTop.offset, atTop.pending, "the top of what has arrived")

        let rows = try XCTUnwrap(try restore.restoreNextHistoryPage())
        engine.withLock { engine.historyPageRestoredLocked(rows: rows) }
        XCTAssertGreaterThan(rows, 0)

        let after = engine.scrollbar
        XCTAssertEqual(
            after.offset, atTop.offset - UInt64(rows),
            "still the oldest row there is, which is now \(rows) rows older")
        XCTAssertEqual(after.offset, after.pending, "and still the top of what has arrived")
    }

    /// The count comes down as pages land, and saturates rather than wrapping
    /// if the pages deliver more than was declared.
    func testPagesCountTheOwedRowsDown() throws {
        let engine = try TerminalEngine(cols: 80, rows: 24)
        engine.declarePendingHistory(rows: engine.scrollbar.total - engine.scrollbar.length + 100)
        XCTAssertEqual(engine.scrollbar.pending, 100)

        engine.withLock { engine.historyPageRestoredLocked(rows: 60) }
        XCTAssertEqual(engine.scrollbar.pending, 40)

        engine.withLock { engine.historyPageRestoredLocked(rows: 0) }
        XCTAssertEqual(engine.scrollbar.pending, 40, "an unapplied page owes the same")

        engine.withLock { engine.historyPageRestoredLocked(rows: 999) }
        XCTAssertEqual(engine.scrollbar.pending, 0, "saturates, never wraps")
    }

    /// However the restore ended, it ended. The declared extent is advisory,
    /// so a snapshot whose pages applied fewer rows than promised must not
    /// leave a sliver of the bar pending for the terminal's lifetime.
    func testClearingDropsWhatIsStillOwed() throws {
        let engine = try TerminalEngine(cols: 80, rows: 24)
        engine.declarePendingHistory(rows: engine.scrollbar.total - engine.scrollbar.length + 100)
        XCTAssertEqual(engine.scrollbar.pending, 100)
        engine.clearPendingHistory()
        XCTAssertEqual(engine.scrollbar.pending, 0)
    }

    /// Adopting a terminal drops the previous one's count. A second snapshot
    /// on one connection is what desync recovery looks like, and the rows the
    /// old snapshot owed have nothing to do with the new one.
    func testAdoptingClearsThePreviousTerminalsCount() throws {
        let source = try makeTerminal(cols: 80, rows: 24, lines: 5_000)
        defer { ghostty_terminal_free(source) }
        let bytes = try encoded(source)

        let engine = try TerminalEngine(cols: 80, rows: 24)
        engine.declarePendingHistory(rows: engine.scrollbar.total - engine.scrollbar.length + 100)
        XCTAssertEqual(engine.scrollbar.pending, 100)

        let restore = try SnapshotRestore(snapshot: bytes)
        engine.adopt(terminal: try restore.ready(), cols: 80, rows: 24)
        XCTAssertEqual(
            engine.scrollbar.pending, 0, "the new terminal owes nothing until it says so")
    }

    // MARK: - The alternate screen

    /// A terminal sitting in a full-screen TUI reports no pending rows.
    ///
    /// The alternate screen has no scrollback of its own, so adding the
    /// primary's owed rows to its bar would invent a scrollable area where
    /// there is none — and `canScroll` gates whether the indicator is drawn at
    /// all, so it would appear over vim.
    func testTheAlternateScreenReportsNoPendingRows() throws {
        let engine = try TerminalEngine(cols: 80, rows: 24)
        engine.declarePendingHistory(rows: engine.scrollbar.total - engine.scrollbar.length + 500)
        XCTAssertEqual(engine.scrollbar.pending, 500)

        engine.write(Data(Array("\u{1b}[?1049h".utf8)))
        let alt = engine.scrollbar
        XCTAssertEqual(alt.pending, 0, "no scrollback on the alternate screen")
        XCTAssertFalse(alt.canScroll, "and so nothing to scroll")

        // Nothing was forgotten: leaving the TUI brings the primary screen
        // back, history and owed rows together.
        engine.write(Data(Array("\u{1b}[?1049l".utf8)))
        XCTAssertEqual(engine.scrollbar.pending, 500, "the count survives the round trip")
    }

    // MARK: - Scrolling

    /// An absolute row round-trips with the offset the scrollbar reports, the
    /// way a scrollbar drag needs it to, with rows still pending.
    ///
    /// Both quantities are in the declared space, so `scroll(.row:)` has to
    /// back out of it before handing a row to libghostty — which knows only
    /// about rows that exist.
    func testAbsoluteRowRoundTripsThroughThePendingOffset() throws {
        let source = try makeTerminal(cols: 80, rows: 24, lines: 20_000)
        defer { ghostty_terminal_free(source) }
        let bytes = try encoded(source)

        let restore = try SnapshotRestore(snapshot: bytes)
        let engine = try TerminalEngine(cols: 80, rows: 24)
        engine.adopt(terminal: try restore.ready(), cols: 80, rows: 24)

        // Deliver some history so there is somewhere to scroll to that is not
        // the top, then declare the rest still owed.
        _ = try restore.restoreNextHistoryPage()
        let delivered = engine.scrollbar
        engine.declarePendingHistory(rows: restore.declaredHistoryRows)
        let pending = engine.scrollbar.pending
        XCTAssertGreaterThan(pending, 0, "history should still be owed")

        // A row inside the delivered region, expressed the way the scrollbar
        // would report it.
        let target = pending + (delivered.total - delivered.length) / 2
        engine.scroll(.row(target))
        XCTAssertEqual(engine.scrollbar.offset, target, "the row the caller asked for")
    }

    /// Dragging into the pending region lands at the oldest row that has
    /// arrived, which is as far up as there is anything to show.
    func testScrollingIntoThePendingRegionStopsAtTheOldestDeliveredRow() throws {
        let engine = try TerminalEngine(cols: 80, rows: 24)
        engine.write(Data(Array((0..<200).map { "line \($0)\r\n" }.joined().utf8)))
        let delivered = engine.scrollbar
        engine.declarePendingHistory(rows: delivered.total - delivered.length + 500)

        engine.scroll(.row(0))
        XCTAssertEqual(
            engine.scrollbar.offset, 500,
            "clamped to the top of the delivered history, which sits below the owed rows")
    }
}
