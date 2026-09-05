//  LaunchBudgetTests.swift
//  The instrumentation the M3 gate is measured with.
//
//  The numbers themselves come from `scripts/bench-launch.sh`, which needs a
//  window and a server. What can be checked here is that the milestones mean
//  what the benchmark reads them as — in particular that "first frame" is the
//  frame carrying the snapshot, not the blank surface drawn at layout, which
//  is already on screen before the attach handshake has even been sent.

import GhosttyVt
import XCTest

final class LaunchBudgetTests: XCTestCase {
    /// Counting from a `@Sendable` callback that fires on the render thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func newTerminal(cols: UInt16, rows: UInt16) throws -> GhosttyTerminal {
        var terminal: GhosttyTerminal?
        try check("ghostty_terminal_new") { ghostty_terminal_new(nil, &terminal, cols, rows) }
        return try XCTUnwrap(terminal)
    }

    /// Process start comes from the kernel rather than from whenever our code
    /// first ran, because the interesting part of a cold launch is dyld and
    /// the Swift runtime, both of which finish before any timer of ours could
    /// start.
    func testProcessStartIsRealAndInThePast() throws {
        let start = try XCTUnwrap(Signposts.processStart)
        let elapsed = try XCTUnwrap(Signposts.sinceLaunch())
        XCTAssertGreaterThan(elapsed, 0)
        XCTAssertLessThan(start, Date())
        // A test process that has been alive for a day is a broken clock.
        XCTAssertLessThan(elapsed, 86_400)
    }

    /// The flag is set by `adopt` and taken by exactly one frame.
    func testAdoptedFlagIsTakenOnce() throws {
        let engine = try TerminalEngine(cols: 20, rows: 5)
        XCTAssertFalse(engine.consumeSnapshotAdopted())

        engine.adopt(terminal: try newTerminal(cols: 20, rows: 5), cols: 20, rows: 5)
        XCTAssertTrue(engine.consumeSnapshotAdopted())
        XCTAssertFalse(engine.consumeSnapshotAdopted())
    }

    /// The measurement the gate depends on: the callback fires for the frame
    /// that shows the snapshot, and not for the frames before it. Timing the
    /// renderer's *first* frame instead would time the blank surface drawn at
    /// layout and report a number that is always the same and always wrong.
    func testFirstFrameIsReportedForTheSnapshotFrame() throws {
        let engine = try TerminalEngine(cols: 20, rows: 5)
        let harness = try RenderHarness(columns: 20, rows: 5, source: engine)
        let counter = Counter()
        harness.renderer.onSnapshotFrame = { _ in counter.increment() }

        _ = try harness.render()
        XCTAssertEqual(counter.count, 0, "a frame before any snapshot is not the first frame")

        engine.adopt(terminal: try newTerminal(cols: 20, rows: 5), cols: 20, rows: 5)
        _ = try harness.render()
        XCTAssertEqual(counter.count, 1)

        _ = try harness.render()
        XCTAssertEqual(counter.count, 1, "reported once per snapshot, not once per frame")

        // A re-attach adopts again, and is worth measuring again.
        engine.adopt(terminal: try newTerminal(cols: 20, rows: 5), cols: 20, rows: 5)
        _ = try harness.render()
        XCTAssertEqual(counter.count, 2)
    }

    /// `withLock` is what makes the history restore safe to run off the main
    /// actor: the decoder writes into the terminal the engine owns, and the
    /// render thread reads it under this same lock.
    func testWithLockSerialisesAgainstTheRenderPath() throws {
        let engine = try TerminalEngine(cols: 40, rows: 10)
        let snapshot = TerminalSnapshot()
        let counter = Counter()

        // One thread taking the lock in a tight loop while the other renders.
        // Without the lock this is a data race on the terminal; with it, both
        // simply make progress.
        let writer = Thread {
            for _ in 0..<200 {
                engine.withLock { counter.increment() }
            }
        }
        writer.start()
        for _ in 0..<200 { _ = engine.updateSnapshot(into: snapshot) }
        while !writer.isFinished { usleep(500) }

        XCTAssertEqual(counter.count, 200)
    }
}
