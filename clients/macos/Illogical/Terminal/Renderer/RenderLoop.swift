//  RenderLoop.swift
//  The render thread and its display link.
//
//  Mirrors what libghostty's `src/renderer/Thread.zig` does with libxev: a
//  dedicated thread woken by the display's vsync, which builds and submits
//  one frame per wake.
//
//  Two properties this exists to get:
//
//  The main thread never participates in rendering. A terminal on a 120 Hz
//  display would otherwise be woken 120 times a second just to ask whether
//  anything changed, and any hitch in glyph rasterization would show up as
//  UI lag.
//
//  An idle terminal costs nothing. After a second with nothing to draw the
//  display link is paused outright, and the engine's wake callback restarts
//  it when bytes arrive. This matters here more than in most apps: the point
//  of this project is that ten idle shells are ten parked terminals costing
//  approximately zero.

import AppKit
import QuartzCore

final class RenderLoop: NSObject, @unchecked Sendable {
    private let renderer: TerminalRenderer

    /// Guards `thread` and `displayLink`, which are set on the main thread
    /// and read from the render thread and from `wake`.
    private let stateLock = NSLock()
    private var thread: Thread?
    private var displayLink: CADisplayLink?

    /// Mirrors `displayLink.isPaused` so `wake` can bail out without a lock
    /// in the common case where the link is already running.
    private let paused = Atomic(false)

    /// Ticks with nothing to draw before we stop the display link. At 60 Hz
    /// that is a second of quiet.
    private static let idleTicksBeforePause = 60
    /// Render-thread only.
    private var idleTicks = 0

    /// Keeps the run loop alive when it has no other sources.
    private let keepAlive = Port()

    init(renderer: TerminalRenderer) {
        self.renderer = renderer
        super.init()
    }

    /// Start the thread. `hostView` supplies the display link, which follows
    /// whichever screen the view is on.
    @MainActor
    func start(hostView: NSView) {
        let link = hostView.displayLink(target: self, selector: #selector(tick))
        let thread = Thread { [weak self] in self?.main() }
        thread.name = "dev.illogical.renderer"
        // Rendering is latency-critical and should not be descheduled behind
        // background work.
        thread.qualityOfService = .userInteractive

        stateLock.lock()
        displayLink = link
        self.thread = thread
        stateLock.unlock()

        thread.start()
    }

    private func main() {
        stateLock.lock()
        let link = displayLink
        let thread = self.thread
        stateLock.unlock()

        let runLoop = RunLoop.current
        runLoop.add(keepAlive, forMode: .common)
        link?.add(to: runLoop, forMode: .common)

        while !(thread?.isCancelled ?? true) {
            // Returns when a source fires; the display link is one, and so
            // is a `perform(on:)` from `wake`.
            runLoop.run(mode: .default, before: .distantFuture)
        }

        link?.invalidate()
        runLoop.remove(keepAlive, forMode: .common)
    }

    func stop() {
        stateLock.lock()
        let thread = self.thread
        self.thread = nil
        stateLock.unlock()

        thread?.cancel()
        // Wake the run loop so it notices the cancellation and unwinds.
        wake(force: true)
    }

    /// Restart a paused display link.
    ///
    /// Called from the connection's reader thread on the clean-to-dirty
    /// edge, so it must be safe from anywhere and cheap when the link is
    /// already running — which is the usual case, since we only pause after
    /// a second of quiet.
    func wake(force: Bool = false) {
        guard force || paused.load() else { return }

        stateLock.lock()
        let thread = self.thread
        stateLock.unlock()

        guard let thread, thread.isExecuting else { return }
        // Hop to the render thread: CADisplayLink's threading contract isn't
        // documented, and this doubles as the run loop wakeup we need when
        // the link is paused and nothing else would fire.
        perform(
            #selector(resume), on: thread, with: nil, waitUntilDone: false,
            modes: [RunLoop.Mode.default.rawValue, RunLoop.Mode.common.rawValue])
    }

    @objc private func resume() {
        idleTicks = 0
        paused.store(false)
        stateLock.lock()
        let link = displayLink
        stateLock.unlock()
        link?.isPaused = false
    }

    @objc private func tick() {
        // The cheap check first: an idle terminal must not pay for a frame
        // build to discover it has nothing to build.
        guard renderer.needsFrame else {
            idleTicks += 1
            if idleTicks >= Self.idleTicksBeforePause, !paused.load() {
                paused.store(true)
                stateLock.lock()
                let link = displayLink
                stateLock.unlock()
                link?.isPaused = true
            }
            return
        }
        idleTicks = 0

        renderer.updateFrame()
        renderer.drawFrame()
    }
}
