//  ScrollAccumulator.swift
//  Turning wheel and trackpad events into whole rows.
//
//  Ported from the delta handling in libghostty's `Surface.scrollCallback`.
//  Two quirks make this more than a division:
//
//  A trackpad reports pixels, a few at a time, so most events are smaller
//  than a row and would round to nothing. The remainder has to carry between
//  events or the terminal never scrolls.
//
//  A wheel reports ticks, but macOS fakes precision for wheels by ramping the
//  tick magnitude with speed — a slow single click arrives as 0.1. Rounding
//  the magnitude out to at least one tick is what stops slow scrolling from
//  being swallowed.

import Foundation

struct ScrollAccumulator {
    /// Sub-row movement carried between events.
    private(set) var pending: Double = 0

    /// Scroll speed. libghostty's defaults: precision deltas pass through,
    /// discrete ticks become three rows each.
    var precisionMultiplier: Double = 1
    var discreteMultiplier: Double = 3

    init(precisionMultiplier: Double = 1, discreteMultiplier: Double = 3) {
        self.precisionMultiplier = precisionMultiplier
        self.discreteMultiplier = discreteMultiplier
    }

    /// Feed one event's vertical delta and get whole rows back.
    ///
    /// `delta` is in the OS's own units — pixels when `precise`, ticks when
    /// not — and keeps the OS's sign convention, where positive means the
    /// content moves down toward older output. The result uses the same
    /// convention; the caller flips it for the viewport axis.
    mutating func rows(delta: Double, precise: Bool, cellHeight: Double) -> Int {
        guard delta != 0, cellHeight > 0 else { return 0 }

        let pixels: Double
        if precise {
            pixels = delta * precisionMultiplier
        } else {
            let ticks = delta > 0 ? Swift.max(delta, 1) : Swift.min(delta, -1)
            pixels = ticks * cellHeight * discreteMultiplier
        }

        let total = pending + pixels
        guard abs(total) >= cellHeight else {
            pending = total
            return 0
        }

        let whole = (total / cellHeight).rounded(.towardZero)
        // Carry the true remainder. libghostty subtracts the *unrounded*
        // quotient at this point, which always leaves zero and quietly drops
        // up to a row of movement on every event that fires.
        pending = total - whole * cellHeight
        return Int(whole)
    }

    /// Rows to move the *viewport* by, given a scroll event's two delta
    /// fields.
    ///
    /// Handles the two things that are easy to get wrong at the AppKit
    /// boundary. `scrollingDeltaY` is the modern field, but not every source
    /// fills it in — synthesized events and some drivers set only the legacy
    /// `deltaY`, which is in lines — so we fall back rather than ignoring the
    /// event. And the sign is flipped: the OS reports positive when the
    /// content should move down, which is toward *older* output, whereas the
    /// viewport axis counts downward from the top of the scrollback.
    mutating func viewportRows(
        scrollingDeltaY: Double,
        legacyDeltaY: Double,
        precise: Bool,
        cellHeight: Double
    ) -> Int {
        var delta = scrollingDeltaY
        var isPrecise = precise
        if delta == 0 {
            delta = legacyDeltaY
            isPrecise = false
        }
        return -rows(delta: delta, precise: isPrecise, cellHeight: cellHeight)
    }

    /// Forget any partial movement. Used when the viewport jumps somewhere
    /// absolute, so a stale fraction doesn't nudge the next scroll.
    mutating func reset() {
        pending = 0
    }
}
