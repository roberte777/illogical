//  SearchNudge.swift
//  Getting the find bar out of the way of what it found.
//
//  The bar floats over the terminal at the top right, which is where a
//  terminal's own output is least often busy — but "least often" is not
//  "never", and the one thing a find bar must never cover is a match. So the
//  bar moves: it starts where it belongs and slides down until nothing it
//  found is underneath it.
//
//  Down rather than left, and rows rather than pixels, because the thing it is
//  dodging is text on a grid. Moving left would put the bar over the middle of
//  a line, which is where output actually lives; moving down lands it in the
//  gap between two rows.
//
//  A pure function of two rectangles and a list, so the behaviour is pinned by
//  tests rather than by looking at it. `SearchBar` does nothing but animate
//  what this returns.

import CoreGraphics

enum SearchNudge {
    /// Clearance kept between the bar and the match it stepped over, in points.
    /// Half a line at the default size: enough that the two do not touch, small
    /// enough that the bar does not drift away from the corner it belongs in.
    static let gap: CGFloat = 6

    /// How far to push the bar down so it covers no match.
    ///
    /// Returns points, always ≥ 0. `limit` is the furthest the bar's *bottom*
    /// may travel — past that the top right is hopelessly busy, and a find bar
    /// halfway down the screen is worse than one covering a hit it has already
    /// scrolled you to. In that case this stops at the last position it
    /// managed, which is still the best of the ones it tried.
    ///
    /// The loop is bounded twice over: by `limit`, and by the requirement that
    /// each pass move strictly further down than the one before it. Matches
    /// that do not overlap the bar horizontally never enter into it, which is
    /// the common case — the bar is a few hundred points wide at the right
    /// edge, and most output is not.
    static func offset(
        bar: CGRect, matches: [CGRect], limit: CGFloat, gap: CGFloat = gap
    ) -> CGFloat {
        guard !matches.isEmpty, bar.width > 0, bar.height > 0 else { return 0 }

        var offset: CGFloat = 0
        // One pass per match at the very worst: each clears at least the
        // lowest one that was blocking, and passes strictly descend.
        for _ in 0..<matches.count {
            let probe = bar.offsetBy(dx: 0, dy: offset).insetBy(dx: -gap, dy: -gap)
            guard
                let lowest = matches.filter({ $0.intersects(probe) }).map(\.maxY).max()
            else { return offset }

            let next = lowest + gap - bar.minY
            // No progress means the blocking match starts above the bar and is
            // taller than the step: nothing more to try.
            guard next > offset else { return offset }
            guard bar.minY + next + bar.height <= limit else { return offset }
            offset = next
        }
        return offset
    }
}
