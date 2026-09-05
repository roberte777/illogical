//  Signposts.swift
//  The launch budget, measured rather than asserted.
//
//  Two numbers decide whether this client is what it claims to be, and both
//  are in docs/GOALS.md G7:
//
//    process exec → window on screen.  Nothing on screen may wait for the
//    network, so this must not move when the server is slow, absent, or
//    holding a hundred megabytes of scrollback.
//
//    snapshot_ready → first frame.     This must not vary with scrollback
//    size. If it does, something is buffering that should be streaming.
//
//  `os_signpost` because Instruments can then line them up against dyld,
//  Metal and the run loop without any of our own bookkeeping. `OSSignposter`
//  checks whether anything is recording before it does any work, so the
//  instrumentation costs nothing when nobody is looking — which is why the
//  per-frame ones are safe to leave in.
//
//  The same milestones also go to `Trace`, because a signpost is only
//  readable from Instruments and a launch benchmark has to be scriptable.
//  See `scripts/bench-launch.sh`.

import Foundation
import OSLog

enum Signposts {
    static let subsystem = "dev.illogical.Illogical"

    /// Process start to window on screen.
    static let launch = OSSignposter(subsystem: subsystem, category: "launch")
    /// Connect, attach, decode, first frame, then history.
    static let attach = OSSignposter(subsystem: subsystem, category: "attach")
    /// Per-frame work on the render thread.
    static let render = OSSignposter(subsystem: subsystem, category: "render")

    // MARK: - Milestones

    /// When this process began executing.
    ///
    /// Not when `main` ran: the interesting part of a cold launch is dyld,
    /// the Swift runtime and SwiftUI's first layout, all of which happen
    /// before any code of ours could start a timer. The kernel knows, so ask
    /// it.
    static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [
            CTL_KERN, KERN_PROC, KERN_PROC_PID, ProcessInfo.processInfo.processIdentifier,
        ]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Date(
            timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }()

    /// Seconds since the process started executing.
    static func sinceLaunch(_ moment: Date = Date()) -> TimeInterval? {
        guard let processStart else { return nil }
        return moment.timeIntervalSince(processStart)
    }

    /// Record a milestone as a one-shot signpost event and a trace line.
    ///
    /// The trace line is what `scripts/bench-launch.sh` reads, so its shape
    /// is load-bearing: `milestone <name> <seconds>`.
    static func milestone(_ name: StaticString, seconds: TimeInterval?, detail: String = "") {
        launch.emitEvent(name)
        guard Trace.isEnabled else { return }
        let value = seconds.map { String(format: "%.4f", $0) } ?? "unknown"
        Trace.log("milestone \(name) \(value)\(detail.isEmpty ? "" : " " + detail)")
    }
}
