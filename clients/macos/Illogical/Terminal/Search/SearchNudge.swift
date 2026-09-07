//  SearchNudge.swift
//  Getting the find bar out of the way of the match you are on.
//
//  The bar floats over the terminal at the top right, which is where a
//  terminal's own output is least often busy — but "least often" is not
//  "never", and the one thing a find bar must never cover is the match it has
//  just taken you to.
//
//  The match it has taken you to, and no other. Dodging every hit on screen
//  was the first shape this had, and it is the wrong one: a query with a
//  column of matches down the right-hand side walks the bar past all of them
//  and halfway down the window, to keep clear of hits nobody is looking at.
//  The selected match is the one the search scrolled to and the one the count
//  is counting; the rest are context, and context is allowed to be behind a
//  floating bar.
//
//  Down rather than left, and rows rather than pixels, because the thing it is
//  dodging is text on a grid. Moving left would put the bar over the middle of
//  a line, which is where output actually lives; moving down lands it in the
//  gap between two rows.
//
//  A pure function of two rectangles, so the behaviour is pinned by tests
//  rather than by looking at it. `SearchBar` does nothing but animate what
//  this returns.

import CoreGraphics

enum SearchNudge {
    /// Clearance kept between the bar and the match it stepped over, in points.
    /// Half a line at the default size: enough that the two do not touch, small
    /// enough that the bar does not drift away from the corner it belongs in.
    static let gap: CGFloat = 6

    /// How far to push the bar down so it does not cover `match`.
    ///
    /// Returns points, always ≥ 0, and 0 whenever there is no selected match or
    /// it is not underneath the bar — which is almost always, since the bar is
    /// a few hundred points at the top right and most output is not.
    ///
    /// `limit` is the furthest the bar's bottom may travel. One match can only
    /// push the bar just past its own last row, so this matters for exactly one
    /// case: a needle long enough to wrap across many lines, whose match is
    /// taller than the space there is to dodge into. A bar halfway down the
    /// window is worse than one overlapping the top of a match that already
    /// covers half the screen, so it stays where it is.
    static func offset(
        bar: CGRect, match: CGRect?, limit: CGFloat, gap: CGFloat = gap
    ) -> CGFloat {
        guard let match, bar.width > 0, bar.height > 0 else { return 0 }
        guard bar.insetBy(dx: -gap, dy: -gap).intersects(match) else { return 0 }

        let offset = match.maxY + gap - bar.minY
        guard offset > 0 else { return 0 }
        guard bar.minY + offset + bar.height <= limit else { return 0 }
        return offset
    }
}
