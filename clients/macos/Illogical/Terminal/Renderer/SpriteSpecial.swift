//  SpriteSpecial.swift
//  Underlines, strikethroughs, overlines and cursors.
//
//  Ported from libghostty's `src/font/sprite/draw/special.zig`. These are the
//  glyphs no font provides: they have to span the cell exactly so that a run
//  of underlined text is one unbroken line, and they have to sit at positions
//  derived from the font's metrics rather than its outlines.
//
//  The canvas extends a quarter cell past each edge, and several of these
//  clamp against that limit rather than the cell: a font with a very low
//  underline position should push the line down as far as it can and then
//  stop, not have it silently clipped away.

import CoreGraphics
import Foundation

enum SpriteSpecial {
    static func underline(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics
    ) {
        let y = min(
            Int(m.underlinePosition),
            Int(height) + canvas.paddingY - Int(m.underlineThickness))
        canvas.rect(
            x: 0, y: y, width: Int(width), height: Int(m.underlineThickness), .on)
    }

    static func underlineDouble(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics
    ) {
        let thick = Int(m.underlineThickness)
        let y = min(
            Int(m.underlinePosition),
            Int(height) + canvas.paddingY - 2 * thick)

        // One stroke a thickness above the underline position and one below,
        // leaving a gap exactly where a single underline would have been.
        canvas.rect(x: 0, y: y - thick, width: Int(width), height: thick, .on)
        canvas.rect(x: 0, y: y + thick, width: Int(width), height: thick, .on)
    }

    static func underlineDotted(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics
    ) {
        let w = Double(width)
        let h = Double(height)
        let pos = Double(m.underlinePosition)
        let thick = Double(m.underlineThickness)

        // sqrt(1/2) times the usual thickness: at equal thickness dotted
        // underlines read as anaemic next to solid ones.
        let radius = (0.5 as Double).squareRoot() * thick

        let padding = Double(canvas.paddingY)
        let y = min(
            // Centre of the stroke.
            pos + 0.5 * thick,
            // As low as we can go without being clipped.
            h + padding - radius.rounded(.up))

        let dotCount = max(
            min(
                // Enough dots that the gaps match the dot diameter,
                (w / (4 * radius)).rounded(.up),
                // but not so many that the gaps fall below a radius,
                (w / (3 * radius)).rounded(.down),
                // and definitely not so many that they fall below a pixel.
                (w / (2 * radius + 1)).rounded(.down)),
            // At minimum, one dot per cell.
            1.0)

        canvas.fillPath(.on) { ctx in
            // Split the cell into dotCount bands with a dot centred in each.
            var x = (w / dotCount) / 2
            for _ in 0..<Int(dotCount) {
                ctx.move(to: CGPoint(x: x + radius, y: y))
                ctx.addArc(
                    center: CGPoint(x: x, y: y), radius: CGFloat(radius),
                    startAngle: 0, endAngle: 2 * .pi, clockwise: false)
                ctx.closePath()
                x += w / dotCount
            }
        }
    }

    static func underlineDashed(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics
    ) {
        let y = min(
            Int(m.underlinePosition),
            Int(height) + canvas.paddingY - Int(m.underlineThickness))

        let dashWidth = width / 3 + 1
        let dashCount = (width / dashWidth) + 1
        var i: UInt32 = 0
        while i < dashCount {
            canvas.rect(
                x: Int(i * dashWidth), y: y,
                width: Int(dashWidth), height: Int(m.underlineThickness), .on)
            i += 2
        }
    }

    static func underlineCurly(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics
    ) {
        let w = Double(width)
        let h = Double(height)
        let pos = Double(m.underlinePosition)
        let lineWidth = Double(m.underlineThickness)

        // Empirically the nicest looking wave.
        let amplitude = w / Double.pi

        // Stay inside the drawable area. The result can still be below the
        // cell, but we don't want the underline to vanish entirely for fonts
        // with bad metadata.
        let padding = Double(canvas.paddingY)
        let top = min(pos, h + padding - amplitude - lineWidth)
        let bottom = top + amplitude

        // Curvature multiplier. 0.4 gives a smooth wiggle.
        let r = 0.4
        let center = 0.5 * w

        // Round caps so adjacent cells join cleanly; the overlap hides them.
        canvas.strokePath(.on, lineWidth: lineWidth, lineCap: .round) { ctx in
            // One full cycle, peaking at the centre of the cell.
            ctx.move(to: CGPoint(x: 0, y: bottom))
            ctx.addCurve(
                to: CGPoint(x: center, y: top),
                control1: CGPoint(x: center * r, y: bottom),
                control2: CGPoint(x: center - center * r, y: top))
            ctx.addCurve(
                to: CGPoint(x: w, y: bottom),
                control1: CGPoint(x: center + center * r, y: top),
                control2: CGPoint(x: w - center * r, y: bottom))
        }
    }

    static func strikethrough(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics
    ) {
        canvas.rect(
            x: 0, y: Int(m.strikethroughPosition),
            width: Int(width), height: Int(m.strikethroughThickness), .on)
    }

    static func overline(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics
    ) {
        // Allowed above the cell, but not past the canvas.
        let y = max(Int(m.overlinePosition), -canvas.paddingY)
        canvas.rect(x: 0, y: y, width: Int(width), height: Int(m.overlineThickness), .on)
    }

    static func cursorRect(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics
    ) {
        canvas.rect(x: 0, y: 0, width: Int(width), height: Int(height), .on)
    }

    static func cursorHollowRect(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics
    ) {
        // Fill then punch out the middle. Not efficient, but this runs once
        // per cursor size and it is the clearest way to write it.
        canvas.rect(x: 0, y: 0, width: Int(width), height: Int(height), .on)
        let t = Int(m.cursorThickness)
        canvas.rect(
            x: t, y: t,
            width: max(0, Int(width) - t * 2),
            height: max(0, Int(height) - t * 2), .off)
    }

    static func cursorBar(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics
    ) {
        // Half the bar hangs over the left edge so it reads as sitting
        // *between* characters rather than biased into one of them. Rounding
        // up first, because a 1px cursor nudged left looks better than one
        // that isn't nudged at all.
        canvas.rect(
            x: -Int((m.cursorThickness + 1) / 2), y: 0,
            width: Int(m.cursorThickness), height: Int(height), .on)
    }

    static func cursorUnderline(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics
    ) {
        let y = min(
            Int(m.underlinePosition),
            Int(height) + canvas.paddingY - Int(m.underlineThickness))
        canvas.rect(
            x: 0, y: y, width: Int(width), height: Int(m.cursorThickness), .on)
    }
}
