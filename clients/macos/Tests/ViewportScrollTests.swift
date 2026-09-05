//  ViewportScrollTests.swift
//  Moving the viewport, and the screen actually following.
//
//  Driven through a real TerminalEngine so these cover the C calls and the
//  snapshot path, not just arithmetic.

import GhosttyVt
import XCTest

final class ViewportScrollTests: XCTestCase {
    private func engine(
        cols: UInt16 = 40, rows: UInt16 = 10, lines: Int = 300
    ) throws
        -> TerminalEngine
    {
        let engine = try TerminalEngine(cols: cols, rows: rows)
        var text = ""
        for i in 0..<lines { text += "line \(i)\r\n" }
        var bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { engine.write(UnsafeRawBufferPointer($0)) }
        return engine
    }

    func testFreshTerminalSitsAtTheBottom() throws {
        let e = try engine()
        let bar = e.scrollbar
        XCTAssertTrue(bar.canScroll)
        XCTAssertFalse(bar.isScrolledBack)
        XCTAssertEqual(bar.offset + bar.length, bar.total)
    }

    func testScrollingUpMovesTheViewport() throws {
        let e = try engine()
        let before = e.scrollbar.offset
        e.scroll(.delta(-5))
        let after = e.scrollbar
        XCTAssertEqual(after.offset, before - 5)
        XCTAssertTrue(after.isScrolledBack)
    }

    func testScrollingDownReturns() throws {
        let e = try engine()
        e.scroll(.delta(-5))
        e.scroll(.delta(5))
        XCTAssertFalse(e.scrollbar.isScrolledBack)
    }

    func testTopAndBottomClamp() throws {
        let e = try engine()
        e.scroll(.top)
        XCTAssertEqual(e.scrollbar.offset, 0)
        e.scroll(.bottom)
        let bar = e.scrollbar
        XCTAssertEqual(bar.offset + bar.length, bar.total)
    }

    /// Scrolling past either end clamps rather than running off.
    func testOverscrollClamps() throws {
        let e = try engine()
        e.scroll(.delta(-100_000))
        XCTAssertEqual(e.scrollbar.offset, 0)
        e.scroll(.delta(100_000))
        let bar = e.scrollbar
        XCTAssertEqual(bar.offset + bar.length, bar.total)
    }

    /// An absolute row round-trips with the offset the scrollbar reports,
    /// which is what lets a scrollbar drag work.
    func testAbsoluteRowRoundTrips() throws {
        let e = try engine()
        e.scroll(.row(42))
        XCTAssertEqual(e.scrollbar.offset, 42)
        e.scroll(.row(7))
        XCTAssertEqual(e.scrollbar.offset, 7)
    }

    /// Output arriving while scrolled up must not drag the viewport along.
    /// Reading history while a build scrolls past is the case that matters.
    func testOutputDoesNotMoveAScrolledViewport() throws {
        let e = try engine()
        e.scroll(.delta(-20))
        let before = e.scrollbar.offset

        var bytes = Array("more output\r\nand more\r\n".utf8)
        bytes.withUnsafeBufferPointer { e.write(UnsafeRawBufferPointer($0)) }

        let after = e.scrollbar
        XCTAssertEqual(
            after.offset, before, "the viewport should stay where the user left it")
        XCTAssertGreaterThan(after.total, before + after.length, "output still arrived")
    }

    /// A terminal with nothing above the screen reports nothing to scroll.
    func testShortTerminalCannotScroll() throws {
        let e = try engine(lines: 3)
        XCTAssertFalse(e.scrollbar.canScroll)
        XCTAssertFalse(e.scrollbar.isScrolledBack)
    }

    func testMouseTrackingReflectsTheMode() throws {
        let e = try engine(lines: 1)
        XCTAssertFalse(e.isMouseTracking)

        // DECSET 1000: send mouse press/release events.
        var on = Array("\u{1b}[?1000h".utf8)
        on.withUnsafeBufferPointer { e.write(UnsafeRawBufferPointer($0)) }
        XCTAssertTrue(e.isMouseTracking)

        var off = Array("\u{1b}[?1000l".utf8)
        off.withUnsafeBufferPointer { e.write(UnsafeRawBufferPointer($0)) }
        XCTAssertFalse(e.isMouseTracking)
    }

    /// The one that matters: moving the viewport has to repaint.
    ///
    /// libghostty's per-row dirty flags describe *content*, not position, so
    /// a scroll leaves every row "clean" and a renderer that trusted them
    /// would show the old screen. The engine forces a full rebuild instead.
    func testScrollingRepaintsTheScreen() throws {
        let e = try engine(cols: 20, rows: 6, lines: 300)
        let h = try RenderHarness(columns: 20, rows: 6, source: e)

        let atBottom = try h.render()
        e.scroll(.top)
        let atTop = try h.render()

        XCTAssertNotEqual(
            atBottom.pixels, atTop.pixels,
            "scrolling to the top rendered the same pixels as the bottom")

        // And scrolling back reproduces the original frame exactly.
        e.scroll(.bottom)
        let backAtBottom = try h.render()
        XCTAssertEqual(
            atBottom.pixels, backAtBottom.pixels,
            "returning to the bottom should reproduce the original frame")
    }

    /// The snapshot the renderer reads must report a full rebuild after a
    /// scroll, not a partial one.
    func testScrollMarksTheSnapshotFullyDirty() throws {
        let e = try engine(cols: 20, rows: 6, lines: 300)
        let h = try RenderHarness(columns: 20, rows: 6, source: e)
        _ = try h.render()

        e.scroll(.delta(-3))
        _ = try h.render()
        XCTAssertEqual(h.renderer.snapshot.dirty, .full)
    }
}
