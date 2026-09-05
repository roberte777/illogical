//  BlinkTests.swift
//  A blinking cursor should cost two frames a second, not a hundred.
//
//  `needsFrame` is what the display link consults on every tick, and if it
//  answers yes whenever the cursor is blinking then an otherwise idle
//  terminal renders at the display's full rate to animate something that
//  changes twice a second. That matters here more than in most apps: an idle
//  terminal costing nothing is the premise of the whole project.

import XCTest

final class BlinkTests: XCTestCase {
    private func harness() throws -> RenderHarness {
        let h = try RenderHarness(columns: 8, rows: 2) { config in
            // Short enough that a test can wait out a phase.
            config.cursorBlinkInterval = 0.05
        }
        h.source.snapshot.cursor = SnapshotCursor(
            hasViewport: true, x: 1, y: 0, wideTail: false, visible: true,
            blinking: true, passwordInput: false, style: .block)
        return h
    }

    func testNoFrameWantedWhileThePhaseHolds() throws {
        let h = try harness()
        _ = try h.render()
        h.source.dirty = false

        XCTAssertFalse(
            h.renderer.needsFrame,
            "asked for a frame with nothing changed and the blink phase the same")
    }

    func testFrameWantedWhenThePhaseFlips() throws {
        let h = try harness()
        _ = try h.render()
        h.source.dirty = false
        XCTAssertFalse(h.renderer.needsFrame)

        // Wait out the phase.
        Thread.sleep(forTimeInterval: 0.06)
        XCTAssertTrue(h.renderer.needsFrame, "the blink phase flipped and nothing noticed")
    }

    /// A non-blinking cursor should never ask for a frame on its own.
    func testSolidCursorNeverAsksForFrames() throws {
        let h = try RenderHarness(columns: 8, rows: 2)
        h.source.snapshot.cursor = SnapshotCursor(
            hasViewport: true, x: 1, y: 0, wideTail: false, visible: true,
            blinking: false, passwordInput: false, style: .block)
        _ = try h.render()
        h.source.dirty = false

        XCTAssertFalse(h.renderer.needsFrame)
        Thread.sleep(forTimeInterval: 0.06)
        XCTAssertFalse(h.renderer.needsFrame, "a solid cursor asked for a frame")
    }

    /// Output resets the blink, so the cursor stays solid while you type.
    func testOutputResetsTheBlink() throws {
        let h = try harness()
        _ = try h.render()
        Thread.sleep(forTimeInterval: 0.06)

        h.renderer.resetBlink()
        h.source.dirty = true
        _ = try h.render()
        h.source.dirty = false

        // Freshly reset, so the cursor is visible and the phase is stable.
        XCTAssertFalse(h.renderer.needsFrame)
    }
}
