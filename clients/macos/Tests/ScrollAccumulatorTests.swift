//  ScrollAccumulatorTests.swift
//  Wheel and trackpad deltas becoming rows.
//
//  Both input devices are easy to get subtly wrong in ways that are annoying
//  rather than broken: a trackpad that needs a hard flick before anything
//  moves, or a wheel whose slow clicks do nothing.

import XCTest

final class ScrollAccumulatorTests: XCTestCase {
    private let cellHeight = 30.0

    // MARK: - Trackpad

    /// A trackpad reports a few pixels at a time. Those must accumulate, not
    /// round to nothing.
    func testSmallPreciseDeltasAccumulate() {
        var a = ScrollAccumulator()
        for _ in 0..<9 {
            XCTAssertEqual(
                a.rows(delta: 3, precise: true, cellHeight: cellHeight), 0,
                "3px should not move a 30px row on its own")
        }
        XCTAssertEqual(
            a.rows(delta: 3, precise: true, cellHeight: cellHeight), 1,
            "ten 3px events make one row")
    }

    /// The leftover after a row fires carries into the next one, so scrolling
    /// doesn't lose ground.
    func testRemainderCarries() {
        var a = ScrollAccumulator()
        XCTAssertEqual(a.rows(delta: 45, precise: true, cellHeight: cellHeight), 1)
        XCTAssertEqual(a.pending, 15, accuracy: 0.001, "half a row should be kept")
        XCTAssertEqual(
            a.rows(delta: 15, precise: true, cellHeight: cellHeight), 1,
            "the carried half plus another half is a whole row")
    }

    /// A big flick moves several rows at once.
    func testLargePreciseDeltaMovesManyRows() {
        var a = ScrollAccumulator()
        XCTAssertEqual(a.rows(delta: 155, precise: true, cellHeight: cellHeight), 5)
        XCTAssertEqual(a.pending, 5, accuracy: 0.001)
    }

    func testDirectionIsPreserved() {
        var a = ScrollAccumulator()
        XCTAssertEqual(a.rows(delta: -60, precise: true, cellHeight: cellHeight), -2)
        a.reset()
        XCTAssertEqual(a.rows(delta: 60, precise: true, cellHeight: cellHeight), 2)
    }

    // MARK: - Wheel

    /// One wheel tick is three rows, libghostty's default.
    func testOneWheelTickIsThreeRows() {
        var a = ScrollAccumulator()
        XCTAssertEqual(a.rows(delta: 1, precise: false, cellHeight: cellHeight), 3)
        XCTAssertEqual(a.rows(delta: -1, precise: false, cellHeight: cellHeight), -3)
    }

    /// macOS reports a slow single click as 0.1 of a tick. Rounding the
    /// magnitude out to a whole tick is what stops slow scrolling being
    /// swallowed entirely.
    func testSlowWheelClickStillScrolls() {
        var a = ScrollAccumulator()
        XCTAssertEqual(
            a.rows(delta: 0.1, precise: false, cellHeight: cellHeight), 3,
            "a slow click should scroll as much as a normal one")
        a.reset()
        XCTAssertEqual(a.rows(delta: -0.1, precise: false, cellHeight: cellHeight), -3)
    }

    /// A fast wheel, which macOS reports with a ramped magnitude, scrolls
    /// proportionally further.
    func testFastWheelScrollsFurther() {
        var a = ScrollAccumulator()
        XCTAssertEqual(a.rows(delta: 4, precise: false, cellHeight: cellHeight), 12)
    }

    // MARK: - Edges

    func testZeroDeltaDoesNothing() {
        var a = ScrollAccumulator()
        XCTAssertEqual(a.rows(delta: 0, precise: true, cellHeight: cellHeight), 0)
        XCTAssertEqual(a.pending, 0)
    }

    /// A degenerate cell height must not divide by zero or scroll wildly.
    func testZeroCellHeightIsIgnored() {
        var a = ScrollAccumulator()
        XCTAssertEqual(a.rows(delta: 100, precise: true, cellHeight: 0), 0)
    }

    func testResetClearsPending() {
        var a = ScrollAccumulator()
        _ = a.rows(delta: 10, precise: true, cellHeight: cellHeight)
        XCTAssertEqual(a.pending, 10, accuracy: 0.001)
        a.reset()
        XCTAssertEqual(a.pending, 0)
    }

    /// Reversing direction mid-gesture unwinds the pending amount rather than
    /// adding to it.
    func testReversingDirectionUnwindsPending() {
        var a = ScrollAccumulator()
        XCTAssertEqual(a.rows(delta: 20, precise: true, cellHeight: cellHeight), 0)
        XCTAssertEqual(a.rows(delta: -20, precise: true, cellHeight: cellHeight), 0)
        XCTAssertEqual(a.pending, 0, accuracy: 0.001)
    }

    /// The multipliers are honoured.
    func testMultipliersApply() {
        var fast = ScrollAccumulator(precisionMultiplier: 2, discreteMultiplier: 1)
        XCTAssertEqual(fast.rows(delta: 30, precise: true, cellHeight: cellHeight), 2)
        fast.reset()
        XCTAssertEqual(fast.rows(delta: 1, precise: false, cellHeight: cellHeight), 1)
    }
}

/// The AppKit boundary: which delta field to believe, and which way is up.
final class ViewportRowsTests: XCTestCase {
    private let cellHeight = 30.0

    /// Positive `scrollingDeltaY` means the content moves down toward older
    /// output, so the viewport moves *up* the scrollback.
    func testSignIsFlippedForTheViewport() {
        var a = ScrollAccumulator()
        XCTAssertEqual(
            a.viewportRows(
                scrollingDeltaY: 60, legacyDeltaY: 0, precise: true, cellHeight: cellHeight),
            -2, "scrolling toward older output should decrease the viewport row")
        a.reset()
        XCTAssertEqual(
            a.viewportRows(
                scrollingDeltaY: -60, legacyDeltaY: 0, precise: true, cellHeight: cellHeight),
            2)
    }

    /// Events that fill in only the legacy field still scroll, and are
    /// treated as line-based ticks.
    func testFallsBackToLegacyDelta() {
        var a = ScrollAccumulator()
        XCTAssertEqual(
            a.viewportRows(
                scrollingDeltaY: 0, legacyDeltaY: 1, precise: true, cellHeight: cellHeight),
            -3, "one legacy tick is three rows, like any other tick")
    }

    /// An event with nothing in either field does nothing — which is exactly
    /// what macOS's synthesized scroll events look like.
    func testEmptyEventDoesNothing() {
        var a = ScrollAccumulator()
        XCTAssertEqual(
            a.viewportRows(
                scrollingDeltaY: 0, legacyDeltaY: 0, precise: true, cellHeight: cellHeight),
            0)
        XCTAssertEqual(a.pending, 0)
    }

    /// The modern field wins when both are present.
    func testModernFieldTakesPrecedence() {
        var a = ScrollAccumulator()
        XCTAssertEqual(
            a.viewportRows(
                scrollingDeltaY: 30, legacyDeltaY: 99, precise: true, cellHeight: cellHeight),
            -1, "a precise 30px delta is one row, not 99 ticks")
    }
}
