//  SurfaceRebindTests.swift
//  Two surfaces over one engine, which is what a split, a pane close and a
//  zoom all produce.
//
//  Any change to a tab's split tree moves the surviving pane to a new position
//  in the view tree, so SwiftUI builds it a fresh `TerminalSurfaceView` while
//  keeping the outgoing one alive — and once the tree change is animated, "a
//  while" is the length of the transition rather than nothing at all.
//  `HostConnection` hands both surfaces the *same* `TerminalEngine`, because a
//  terminal has one controller however many views of it come and go.
//
//  That makes the engine's per-view state a slot two owners fight over, and the
//  loser is whichever one is torn down last. Both tests here are regressions:
//  before the identity check, the outgoing surface's teardown cleared the wake
//  callback the live surface had just installed, the display link paused after
//  a second of quiet, and the pane stopped repainting until it was touched.

import AppKit
import XCTest

@MainActor
final class SurfaceRebindTests: XCTestCase {
    private final class Recorder: TerminalSurfaceDelegate {
        var resizes: [(cols: UInt16, rows: UInt16)] = []
        func surfaceIsReady(_ surface: TerminalSurfaceView) {}
        func surface(_ surface: TerminalSurfaceView, send bytes: [UInt8]) {}
        func surface(_ surface: TerminalSurfaceView, resizeTo cols: UInt16, rows: UInt16) {
            resizes.append((cols, rows))
        }
        func surfaceDidBecomeFocused(_ surface: TerminalSurfaceView) {}
        func surface(_ surface: TerminalSurfaceView, didPresentFirstFrameAt moment: Date) {}
        func surfaceShouldClose(_ surface: TerminalSurfaceView) -> Bool { false }
    }

    /// Counts wakes. A box rather than a captured `var` because the callback is
    /// `@Sendable` — in the app it is called from the connection's reader
    /// thread, which is the whole reason the slot exists.
    private final class Wakes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func record() { lock.withLock { value += 1 } }
    }

    // MARK: - The engine's side of it

    /// The whole bug, at the layer it lives in: whoever bound last owns the
    /// callback, and an earlier owner going away must not take it.
    func testADisplacedViewDoesNotTakeTheLiveCallbackWithIt() throws {
        let engine = try TerminalEngine(cols: 80, rows: 24)
        let outgoing = NSObject()
        let live = NSObject()

        let outgoingWakes = Wakes()
        let liveWakes = Wakes()
        engine.bind(outgoing) { outgoingWakes.record() }
        engine.bind(live) { liveWakes.record() }

        // The order the animation produces: the new surface attaches, and the
        // old one is dismantled ~170 ms later when its transition finishes.
        engine.unbind(outgoing)

        XCTAssertTrue(engine.isBound(live))
        XCTAssertFalse(engine.isBound(outgoing))

        wake(engine)
        XCTAssertEqual(liveWakes.count, 1, "the live surface's display link was never restarted")
        XCTAssertEqual(outgoingWakes.count, 0)
    }

    /// The other half: unbinding the view that *is* bound really does clear it,
    /// so a surface genuinely going away does not leave a callback pointing at
    /// a stopped render loop.
    func testUnbindingTheBoundViewClearsIt() throws {
        let engine = try TerminalEngine(cols: 80, rows: 24)
        let view = NSObject()
        let wakes = Wakes()
        engine.bind(view) { wakes.record() }

        engine.unbind(view)

        XCTAssertFalse(engine.isBound(view))
        wake(engine)
        XCTAssertEqual(wakes.count, 0)
    }

    // MARK: - The surface's side of it

    /// `teardownRendering` runs when a surface leaves its window, which is what
    /// SwiftUI does to the outgoing pane at the end of a split's transition.
    /// It must go through the identity check rather than clearing outright.
    func testTearingDownAnOutgoingSurfaceLeavesTheLiveOneBound() throws {
        let engine = try TerminalEngine(cols: 80, rows: 24)
        let outgoing = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let live = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        outgoing.engine = engine
        live.engine = engine
        XCTAssertTrue(engine.isBound(live))

        // A view removed from its window: `window` is already nil by the time
        // AppKit calls this, which is the branch that tears rendering down.
        outgoing.viewDidMoveToWindow()

        XCTAssertTrue(
            engine.isBound(live),
            "the outgoing surface's teardown cleared the live surface's binding")
    }

    /// A displaced surface is still laid out while it fades, and at the *old*
    /// geometry — so without the ownership check it can report a full-window
    /// grid after the surface that replaced it already reported the right one,
    /// leaving the PTY's winsize larger than the pane it is drawn in.
    func testADisplacedSurfaceDoesNotResizeThePty() throws {
        let (window, view, recorder, engine) = try windowed()
        defer { close(window) }

        // Control: while this surface owns the engine, a resize is reported.
        resize(view, to: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertFalse(recorder.resizes.isEmpty, "a bound surface must report its grid")

        // Now a second surface takes the engine, as a split's new pane does.
        let live = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        live.engine = engine
        XCTAssertFalse(engine.isBound(view))

        recorder.resizes.removeAll()
        resize(view, to: NSRect(x: 0, y: 0, width: 780, height: 400))
        XCTAssertEqual(
            recorder.resizes.count, 0,
            "a displaced surface resized the PTY out from under the live one")
    }

    // MARK: - Helpers

    /// Drive one clean-to-dirty edge, which is the only thing that wakes.
    private func wake(_ engine: TerminalEngine) {
        // `updateSnapshot` is what clears the dirty flag; without it the engine
        // is born dirty and a write is not an edge.
        _ = engine.updateSnapshot(into: TerminalSnapshot())
        let bytes = Array("x".utf8)
        bytes.withUnsafeBufferPointer { engine.write(UnsafeRawBufferPointer($0)) }
    }

    /// A surface in a window, laid out once so it has a renderer and a grid.
    private func windowed() throws
        -> (NSWindow, TerminalSurfaceView, Recorder, TerminalEngine)
    {
        let engine = try TerminalEngine(cols: 80, rows: 24)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        // Otherwise `close()` releases it and ARC releases it again.
        window.isReleasedWhenClosed = false
        let view = TerminalSurfaceView(frame: window.contentLayoutRect)
        let recorder = Recorder()
        view.delegate = recorder
        window.contentView = view
        view.engine = engine
        view.layoutSubtreeIfNeeded()
        return (window, view, recorder, engine)
    }

    private func resize(_ view: TerminalSurfaceView, to frame: NSRect) {
        view.frame = frame
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    /// Take the view out of its window first, which stops the render thread.
    private func close(_ window: NSWindow) {
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        window.close()
    }
}
