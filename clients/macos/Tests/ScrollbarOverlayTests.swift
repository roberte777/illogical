//  ScrollbarOverlayTests.swift
//  Where the scroll knob sits.
//
//  Position and size are pure arithmetic over the scrollable area, and both
//  ends have to land exactly — a knob that stops short of the bottom when you
//  are at the live output reads as "there is more below", which is a lie.

import XCTest

final class ScrollbarOverlayTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    private func knob(total: UInt64, offset: UInt64, length: UInt64) -> CGRect {
        let overlay = ScrollbarOverlay()
        overlay.update(
            TerminalEngine.ScrollbarState(total: total, offset: offset, length: length),
            in: bounds, scale: 2)
        return overlay.layer.frame
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
        ] {
            let overlay = ScrollbarOverlay()
            overlay.update(state, in: bounds, scale: 2)
            let f = overlay.layer.frame
            XCTAssertFalse(f.origin.y.isNaN, "NaN origin for \(state)")
            XCTAssertFalse(f.height.isNaN, "NaN height for \(state)")
        }
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
