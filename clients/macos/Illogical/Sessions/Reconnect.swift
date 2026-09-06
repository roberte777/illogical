//  Reconnect.swift
//  When to try a connection again.
//
//  Network loss is not a new failure mode for this protocol: a connection that
//  goes away is a client that has missed output, and the recovery for that is
//  already written down — throw the terminal state away and replay the attach
//  handshake. See docs/PROTOCOL.md, "Desync". So reconnecting is only the
//  question of *when*, and re-attaching is a path that already exists and is
//  already O(screen).
//
//  Two things use this: a host's control connection, and each terminal's own.
//  Over SSH they are the same TCP connection underneath — `ControlMaster`
//  multiplexes them — so when a network comes back they all recover together
//  and only the first pays for a handshake.

import Foundation

/// An exponential backoff with a ceiling.
///
/// Retried forever rather than a bounded number of times, on purpose: a laptop
/// closed overnight should find its terminals in the morning, and "give up
/// after five minutes" would be exactly the case where that fails. The ceiling
/// is what keeps forever cheap — a host that is genuinely gone costs one
/// connection attempt every half minute, not a spin.
struct Backoff {
    /// The first wait. Short enough that a connection dropped by a sleeping
    /// wifi radio comes back before the user has finished noticing.
    static let initial: TimeInterval = 0.25
    /// The longest wait between attempts.
    static let ceiling: TimeInterval = 30
    static let factor: Double = 2

    private(set) var attempt = 0

    /// How long to wait before attempt number `attempt`, then advance.
    mutating func next() -> TimeInterval {
        let delay = Self.delay(forAttempt: attempt)
        attempt += 1
        return delay
    }

    mutating func reset() {
        attempt = 0
    }

    /// Pure, so the schedule can be asserted without waiting for it.
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return initial }
        let scaled = initial * pow(factor, Double(attempt))
        return min(scaled, ceiling)
    }
}
