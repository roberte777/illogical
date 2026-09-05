//  Signposts.swift
//  The launch and attach budgets, measured rather than asserted.
//
//  docs/GOALS.md G3 and G7 make two timing claims: the window is up before any
//  network work completes, and the first frame lands within a round trip plus
//  decode *regardless of how much scrollback the session has*. Neither is worth
//  much as prose. These signposts put both on an Instruments timeline.
//
//  Capture with:
//      xcrun xctrace record --template 'os_signpost' --attach Illogical
//  or watch them live in Instruments' os_signpost track.

import Foundation
import OSLog

enum Signposts {
    static let subsystem = "dev.illogical.Illogical"

    static let launch = OSSignposter(
        subsystem: subsystem, category: "launch")
    static let attach = OSSignposter(
        subsystem: subsystem, category: "attach")
    static let render = OSSignposter(
        subsystem: subsystem, category: "render")

    /// Process start, so "cold launch to window visible" is measurable rather
    /// than inferred from whenever SwiftUI happened to run.
    nonisolated(unsafe) static var processStart = Date()

    static func markWindowVisible() {
        let elapsed = Date().timeIntervalSince(processStart) * 1000
        launch.emitEvent(
            "window-visible",
            "\(String(format: "%.1f", elapsed))ms since process start")
        Trace.log("launch: window visible after \(String(format: "%.1f", elapsed))ms")
    }
}
