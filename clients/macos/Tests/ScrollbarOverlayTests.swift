//  ScrollbarOverlayTests.swift
//  Where the scroll knob sits.
//
//  Position and size are pure arithmetic over the scrollable area, and both
//  ends have to land exactly — a knob that stops short of the bottom when you
//  are at the live output reads as "there is more below", which is a lie.

import XCTest

final class ScrollbarOverlayTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    private func overlay(
        total: UInt64, offset: UInt64, length: UInt64, pending: UInt64 = 0
    ) -> ScrollbarOverlay {
        let overlay = ScrollbarOverlay()
        overlay.update(
            TerminalEngine.ScrollbarState(
                total: total, offset: offset, length: length, pending: pending),
            in: bounds, scale: 2)
        return overlay
    }

    private func knob(total: UInt64, offset: UInt64, length: UInt64) -> CGRect {
        overlay(total: total, offset: offset, length: length).knobFrame
    }

    /// The knob covers the visible fraction of the scrollable area.
    func testKnobHeightTracksTheVisibleFraction() {
        let quarter = knob(total: 400, offset: 0, length: 100)
        let half = knob(total: 200, offset: 0, length: 100)
        XCTAssertLessThan(quarter.height, half.height)
        XCTAssertEqual(quarter.height, 600 * 0.25, accuracy: 4, "roughly a quarter of the track")
    }

    /// A vast scrollback would otherwise give a knob too small to see or
    /// grab.
    func testKnobHasAMinimumHeight() {
        let tiny = knob(total: 1_000_000, offset: 0, length: 10)
        XCTAssertGreaterThanOrEqual(tiny.height, 24)
    }

    func testAtTheTopTheKnobIsAtTheTop() {
        let r = knob(total: 400, offset: 0, length: 100)
        XCTAssertEqual(r.minY, 2, accuracy: 0.5, "flush with the top inset")
    }

    /// At the live output the knob must reach the bottom exactly, including
    /// when it has been clamped to its minimum height.
    func testAtTheBottomTheKnobReachesTheBottom() {
        for (total, length) in [(UInt64(400), UInt64(100)), (1_000_000, 10)] {
            let r = knob(total: total, offset: total - length, length: length)
            XCTAssertEqual(
                r.maxY, bounds.height - 2, accuracy: 0.5,
                "knob should end at the bottom inset for total=\(total)")
        }
    }

    func testMidwayIsMidway() {
        let r = knob(total: 400, offset: 150, length: 100)
        let travel = bounds.height - 4 - r.height
        XCTAssertEqual(r.minY, 2 + travel * 0.5, accuracy: 1)
    }

    /// A terminal with nothing to scroll must not produce a NaN frame.
    func testDegenerateStatesAreSafe() {
        for state in [
            TerminalEngine.ScrollbarState(total: 0, offset: 0, length: 0),
            TerminalEngine.ScrollbarState(total: 10, offset: 0, length: 10),
            TerminalEngine.ScrollbarState(total: 0, offset: 0, length: 0, pending: 0),
            TerminalEngine.ScrollbarState(total: 10, offset: 10, length: 10, pending: 10),
        ] {
            let overlay = ScrollbarOverlay()
            overlay.update(state, in: bounds, scale: 2)
            for f in [overlay.knobFrame, overlay.pendingFrame ?? .zero] {
                XCTAssertFalse(f.origin.y.isNaN, "NaN origin for \(state)")
                XCTAssertFalse(f.height.isNaN, "NaN height for \(state)")
            }
        }
    }

    // MARK: - The loading state

    /// Nothing pending, nothing drawn. This is every terminal that is not
    /// midway through an attach, which is almost all of them almost always.
    func testNothingPendingDrawsNoPendingRegion() {
        XCTAssertNil(overlay(total: 400, offset: 300, length: 100).pendingFrame)
    }

    /// The pending region covers the undelivered fraction of the area, and
    /// sits at the top of the track where the oldest history goes.
    func testPendingRegionCoversTheUndeliveredFraction() throws {
        let bar = overlay(total: 400, offset: 300, length: 100, pending: 100)
        let region = try XCTUnwrap(bar.pendingFrame)
        XCTAssertEqual(region.minY, 2, accuracy: 0.5, "flush with the top inset")
        XCTAssertEqual(region.height, 596 * 0.25, accuracy: 1, "a quarter of the area is owed")
    }

    /// The two marks meet: scrolled as far back as the delivered history goes,
    /// the knob's top edge is the pending region's bottom edge.
    ///
    /// This is the whole visual claim. A gap would read as history that exists
    /// and is reachable but is not being drawn; an overlap would read as the
    /// viewport already being inside the part that has not arrived. They are
    /// the same boundary and they have to land on the same pixel.
    func testTheKnobMeetsThePendingRegionAtTheOldestDeliveredRow() throws {
        // Offset == pending is "scrolled to the top of what has arrived": the
        // rows above the viewport are exactly the ones still owed.
        let bar = overlay(total: 1000, offset: 200, length: 300, pending: 200)
        let region = try XCTUnwrap(bar.pendingFrame)
        XCTAssertEqual(
            bar.knobFrame.minY, region.maxY, accuracy: 0.5,
            "the knob should rest on the pending region, not overlap or float above it")
    }

    /// As history lands the region shrinks and the knob does not move.
    ///
    /// This is the bug the whole mechanism exists to kill, and the two halves
    /// below are the before and after of it. One page of 50 rows lands into a
    /// viewport parked at the oldest row that had arrived; the user has not
    /// touched the wheel.
    ///
    /// Described by what has been *delivered* — which is all the bar could say
    /// before — the area grows by 50 and the viewport is 50 rows down it, and
    /// those do not cancel: the knob slides. Described by what has been
    /// *declared*, the 50 rows move out of `pending` and into `offset`, the
    /// sum that positions the knob is unchanged, and only the pending region
    /// shrinks.
    func testDeliveringHistoryDoesNotMoveTheKnob() throws {
        let deliveredBefore = overlay(total: 800, offset: 0, length: 300)
        let deliveredAfter = overlay(total: 850, offset: 50, length: 300)
        XCTAssertNotEqual(
            deliveredBefore.knobFrame.minY, deliveredAfter.knobFrame.minY,
            "the delivered-only framing is what used to move the knob")

        let before = overlay(total: 1000, offset: 200, length: 300, pending: 200)
        let after = overlay(total: 1000, offset: 200, length: 300, pending: 150)
        XCTAssertEqual(
            before.knobFrame, after.knobFrame,
            "the viewport did not move, so neither should the knob")
        XCTAssertLessThan(
            try XCTUnwrap(after.pendingFrame).height,
            try XCTUnwrap(before.pendingFrame).height,
            "the pending region should shrink as history lands")
    }

    /// A terminal whose history has not started arriving is all pending, and
    /// the knob still sits at the live output at the bottom.
    func testFullyPendingHistoryStillPinsTheKnobToTheBottom() {
        let bar = overlay(total: 1000, offset: 976, length: 24, pending: 976)
        XCTAssertEqual(
            bar.knobFrame.maxY, bounds.height - 2, accuracy: 0.5,
            "a terminal at the live output is at the bottom, however much is owed")
        XCTAssertNotNil(bar.pendingFrame, "and the whole history above it is pending")
    }

    /// The indicator starts hidden and only appears when asked.
    func testStartsHidden() {
        let overlay = ScrollbarOverlay()
        XCTAssertEqual(overlay.layer.opacity, 0)
        overlay.show()
        XCTAssertEqual(overlay.layer.opacity, 1)
        overlay.hide()
        XCTAssertEqual(overlay.layer.opacity, 0)
    }
}
