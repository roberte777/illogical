//  SpritePowerline.swift
//  Powerline and Powerline Extra symbols | U+E0B0...U+E0D4
//  https://github.com/ryanoasis/powerline-extra-symbols
//
//  Ported from libghostty's `src/font/sprite/draw/powerline.zig`.
//
//  Only the geometric separators, not the stylized ones. These matter more
//  than most sprite glyphs: a powerline prompt's whole appearance depends on
//  the separator meeting the background of the segment beside it with no
//  seam, which means it must be exactly cell-sized and exactly aligned. Fonts
//  that ship these glyphs frequently get the advance width wrong.

import CoreGraphics
import Foundation

enum SpritePowerline {
    static let range: ClosedRange<UInt32> = 0xE0B0...0xE0D4

    /// Codepoints in the range we actually draw. Anything else falls through
    /// to the font, which is the right answer for the stylized variants.
    static func has(_ cp: UInt32) -> Bool {
        switch cp {
        case 0xE0B0...0xE0BF, 0xE0D2, 0xE0D4: return true
        default: return false
        }
    }

    static func draw(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        let w = Double(width)
        let h = Double(height)

        switch cp {
        //  filled right-pointing triangle
        case 0xE0B0:
            canvas.fillTriangle(
                SpritePoint(0, 0), SpritePoint(w, h / 2), SpritePoint(0, h), .on)

        //  outlined right-pointing chevron
        case 0xE0B1: chevronRight(canvas, w, h, m)

        //  filled left-pointing triangle
        case 0xE0B2:
            canvas.fillTriangle(
                SpritePoint(w, 0), SpritePoint(0, h / 2), SpritePoint(w, h), .on)

        //  outlined left-pointing chevron
        case 0xE0B3:
            chevronRight(canvas, w, h, m)
            canvas.flipHorizontal()

        //  filled left half-circle
        case 0xE0B4: halfCircle(canvas, w, h)

        //  outlined left half-circle
        case 0xE0B5: halfCircleOutline(canvas, w, h, m)

        //  filled right half-circle
        case 0xE0B6:
            halfCircle(canvas, w, h)
            canvas.flipHorizontal()

        //  outlined right half-circle
        case 0xE0B7:
            halfCircleOutline(canvas, w, h, m)
            canvas.flipHorizontal()

        //  filled bottom-left triangle
        case 0xE0B8:
            canvas.fillTriangle(
                SpritePoint(0, 0), SpritePoint(w, h), SpritePoint(0, h), .on)

        //  its diagonal alone
        case 0xE0B9: SpriteBox.lightDiagonalUpperLeftToLowerRight(m, canvas)

        //  filled bottom-right triangle
        case 0xE0BA:
            canvas.fillTriangle(
                SpritePoint(w, 0), SpritePoint(w, h), SpritePoint(0, h), .on)

        //  its diagonal alone
        case 0xE0BB: SpriteBox.lightDiagonalUpperRightToLowerLeft(m, canvas)

        //  filled top-left triangle
        case 0xE0BC:
            canvas.fillTriangle(
                SpritePoint(0, 0), SpritePoint(w, 0), SpritePoint(0, h), .on)

        //  its diagonal alone
        case 0xE0BD: SpriteBox.lightDiagonalUpperRightToLowerLeft(m, canvas)

        //  filled top-right triangle
        case 0xE0BE:
            canvas.fillTriangle(
                SpritePoint(0, 0), SpritePoint(w, 0), SpritePoint(w, h), .on)

        //  its diagonal alone
        case 0xE0BF: SpriteBox.lightDiagonalUpperLeftToLowerRight(m, canvas)

        //  split right-pointing wedge
        case 0xE0D2: wedge(canvas, w, h, m)

        //  split left-pointing wedge
        case 0xE0D4:
            wedge(canvas, w, h, m)
            canvas.flipHorizontal()

        default: break
        }
    }

    private static func chevronRight(
        _ canvas: SpriteCanvas, _ w: Double, _ h: Double, _ m: GridMetrics
    ) {
        canvas.strokePath(
            .on, lineWidth: Double(SpriteThickness.light.height(m.boxThickness)),
            lineCap: .butt
        ) { ctx in
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: w, y: h / 2))
            ctx.addLine(to: CGPoint(x: 0, y: h))
        }
    }

    /// Coefficient for approximating a quarter circle with a cubic Bézier.
    private static let arcC: Double = (2.0.squareRoot() - 1.0) * 4.0 / 3.0

    private static func halfCircle(_ canvas: SpriteCanvas, _ w: Double, _ h: Double) {
        let r = min(w, h / 2)
        canvas.fillPath(.on) { ctx in
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addCurve(
                to: CGPoint(x: r, y: r),
                control1: CGPoint(x: r * arcC, y: 0),
                control2: CGPoint(x: r, y: r - r * arcC))
            ctx.addLine(to: CGPoint(x: r, y: h - r))
            ctx.addCurve(
                to: CGPoint(x: 0, y: h),
                control1: CGPoint(x: r, y: h - r + r * arcC),
                control2: CGPoint(x: r * arcC, y: h))
            ctx.closePath()
        }
    }

    private static func halfCircleOutline(
        _ canvas: SpriteCanvas, _ w: Double, _ h: Double, _ m: GridMetrics
    ) {
        let r = min(w, h / 2)
        canvas.innerStrokePath(.on, lineWidth: Double(m.boxThickness)) { path in
            // The 1px horizontal segments at each end force the stroke to be
            // butt-capped exactly perpendicular. Starting straight into the
            // curve would leave the caps very slightly sloped.
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 1, y: 0))
            path.addCurve(
                to: CGPoint(x: r, y: r),
                control1: CGPoint(x: r * arcC, y: 0),
                control2: CGPoint(x: r, y: r - r * arcC))
            path.addLine(to: CGPoint(x: r, y: h - r))
            path.addCurve(
                to: CGPoint(x: 1, y: h),
                control1: CGPoint(x: r, y: h - r + r * arcC),
                control2: CGPoint(x: r * arcC, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
        }
    }

    /// Two triangles meeting at the middle with a gap of one line width, so
    /// it reads as a split arrow rather than a solid one.
    private static func wedge(
        _ canvas: SpriteCanvas, _ w: Double, _ h: Double, _ m: GridMetrics
    ) {
        let t = Double(m.boxThickness)

        canvas.fillPath(.on) { ctx in
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: w, y: 0))
            ctx.addLine(to: CGPoint(x: w / 2, y: h / 2 - t / 2))
            ctx.addLine(to: CGPoint(x: 0, y: h / 2 - t / 2))
            ctx.closePath()
        }

        canvas.fillPath(.on) { ctx in
            ctx.move(to: CGPoint(x: 0, y: h))
            ctx.addLine(to: CGPoint(x: w, y: h))
            ctx.addLine(to: CGPoint(x: w / 2, y: h / 2 + t / 2))
            ctx.addLine(to: CGPoint(x: 0, y: h / 2 + t / 2))
            ctx.closePath()
        }
    }
}
