//  SpriteCanvas.swift
//  An 8-bit alpha canvas for drawing sprite glyphs.
//
//  Ported from libghostty's `src/font/sprite/canvas.zig`. libghostty draws
//  these with z2d, its own vector library, because it has to work on Linux
//  too; we have CoreGraphics, so paths and curves go through a CGContext.
//
//  Rectangles deliberately do *not* go through CoreGraphics. Box drawing has
//  to tile seamlessly with the cell to its right, so every rectangle edge
//  must land exactly on a pixel boundary with no antialiasing. Writing those
//  bytes directly is both exact and faster than a fill.
//
//  Coordinates are cell-relative with +Y *down*, matching the draw code we
//  ported. The canvas is larger than the cell by `padding` on each side, so a
//  glyph may legitimately overflow its cell (an undercurl dipping below the
//  baseline, a box join reaching into its neighbour).

import CoreGraphics
import Foundation

/// A drawing value. `on` and `off` are the common cases; the shade blocks use
/// intermediate values.
struct SpriteColor {
    var value: UInt8
    static let on = SpriteColor(value: 255)
    static let off = SpriteColor(value: 0)
    init(value: UInt8) { self.value = value }
}

struct SpritePoint {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

final class SpriteCanvas {
    /// Canvas dimensions including padding.
    let width: Int
    let height: Int
    let paddingX: Int
    let paddingY: Int

    /// Transparent margins found by `trim`, excluded when writing to an atlas.
    private(set) var clipTop: Int = 0
    private(set) var clipLeft: Int = 0
    private(set) var clipRight: Int = 0
    private(set) var clipBottom: Int = 0

    private let buffer: UnsafeMutablePointer<UInt8>
    private var context: CGContext?

    init(cellWidth: Int, cellHeight: Int, paddingX: Int, paddingY: Int) {
        self.width = cellWidth + 2 * paddingX
        self.height = cellHeight + 2 * paddingY
        self.paddingX = paddingX
        self.paddingY = paddingY
        let count = max(1, width * height)
        buffer = .allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
    }

    deinit {
        buffer.deallocate()
    }

    // MARK: - Direct pixel drawing (exact, unantialiased)

    /// Set one pixel. Out-of-bounds writes are dropped rather than clamped:
    /// draw code legitimately reaches past the cell and the padding is what
    /// decides how far it gets.
    func pixel(_ x: Int, _ y: Int, _ color: SpriteColor) {
        let px = x + paddingX
        let py = y + paddingY
        guard px >= 0, px < width, py >= 0, py < height else { return }
        buffer[py * width + px] = color.value
    }

    /// Fill an axis-aligned rectangle, exactly.
    func rect(x: Int, y: Int, width w: Int, height h: Int, _ color: SpriteColor) {
        guard w > 0, h > 0 else { return }
        // Clip in cell space before converting, so the row memset below can
        // be unchecked.
        let x0 = max(0, x + paddingX)
        let y0 = max(0, y + paddingY)
        let x1 = min(width, x + paddingX + w)
        let y1 = min(height, y + paddingY + h)
        guard x1 > x0, y1 > y0 else { return }
        for row in y0..<y1 {
            memset(buffer + row * width + x0, Int32(color.value), x1 - x0)
        }
    }

    /// Fill the box between two corners. The main primitive: lines are just
    /// skinny boxes.
    func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ color: SpriteColor) {
        let lox = min(x0, x1)
        let loy = min(y0, y1)
        rect(x: lox, y: loy, width: max(x0, x1) - lox, height: max(y0, y1) - loy, color)
    }

    // MARK: - Path drawing (antialiased)

    /// A CGContext over the same buffer, already transformed so that drawing
    /// uses cell-relative, +Y-down coordinates.
    private func cgContext() -> CGContext? {
        if let context { return context }
        guard
            let ctx = CGContext(
                data: buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpace(name: CGColorSpace.linearGray)!,
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }
        // Bitmap contexts are +Y-up; flip so the ported draw code's
        // coordinates mean what they say, then shift past the padding.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(paddingX), y: CGFloat(paddingY))
        ctx.setShouldAntialias(true)
        context = ctx
        return ctx
    }

    /// Fill a closed path built by `build`.
    func fillPath(_ color: SpriteColor, _ build: (CGContext) -> Void) {
        guard let ctx = cgContext() else { return }
        ctx.saveGState()
        ctx.beginPath()
        build(ctx)
        ctx.setFillColor(gray: 1, alpha: CGFloat(color.value) / 255)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Stroke a path built by `build`.
    func strokePath(
        _ color: SpriteColor,
        lineWidth: Double,
        lineCap: CGLineCap = .butt,
        lineJoin: CGLineJoin = .miter,
        _ build: (CGContext) -> Void
    ) {
        guard let ctx = cgContext() else { return }
        ctx.saveGState()
        ctx.beginPath()
        build(ctx)
        ctx.setLineWidth(CGFloat(lineWidth))
        ctx.setLineCap(lineCap)
        ctx.setLineJoin(lineJoin)
        ctx.setStrokeColor(gray: 1, alpha: CGFloat(color.value) / 255)
        ctx.strokePath()
        ctx.restoreGState()
    }

    func fillTriangle(_ p0: SpritePoint, _ p1: SpritePoint, _ p2: SpritePoint, _ color: SpriteColor)
    {
        fillPath(color) { ctx in
            ctx.move(to: CGPoint(x: p0.x, y: p0.y))
            ctx.addLine(to: CGPoint(x: p1.x, y: p1.y))
            ctx.addLine(to: CGPoint(x: p2.x, y: p2.y))
            ctx.closePath()
        }
    }

    func fillQuad(
        _ p0: SpritePoint, _ p1: SpritePoint, _ p2: SpritePoint, _ p3: SpritePoint,
        _ color: SpriteColor
    ) {
        fillPath(color) { ctx in
            ctx.move(to: CGPoint(x: p0.x, y: p0.y))
            ctx.addLine(to: CGPoint(x: p1.x, y: p1.y))
            ctx.addLine(to: CGPoint(x: p2.x, y: p2.y))
            ctx.addLine(to: CGPoint(x: p3.x, y: p3.y))
            ctx.closePath()
        }
    }

    func line(from p0: SpritePoint, to p1: SpritePoint, thickness: Double, _ color: SpriteColor) {
        strokePath(color, lineWidth: thickness, lineCap: .butt) { ctx in
            ctx.move(to: CGPoint(x: p0.x, y: p0.y))
            ctx.addLine(to: CGPoint(x: p1.x, y: p1.y))
        }
    }

    /// Stroke a path *inside* itself: the stroke sits entirely within the
    /// region the path encloses, rather than straddling it.
    ///
    /// libghostty offsets the path inward by half the line width and strokes
    /// that. CoreGraphics has no path-offset, so we get the same result by
    /// stroking at double width and clipping to the enclosed region — the
    /// outer half of the stroke is clipped away and the inner half remains.
    ///
    /// `build` should produce an *open* path; closing it is what defines the
    /// region.
    func innerStrokePath(
        _ color: SpriteColor,
        lineWidth: Double,
        _ build: (CGMutablePath) -> Void
    ) {
        guard let ctx = cgContext() else { return }
        let path = CGMutablePath()
        build(path)
        guard let region = path.mutableCopy() else { return }
        region.closeSubpath()
        let stroked = path.copy(
            strokingWithWidth: CGFloat(lineWidth * 2), lineCap: .butt,
            lineJoin: .miter, miterLimit: 10)

        ctx.saveGState()
        ctx.addPath(region)
        ctx.clip()
        ctx.addPath(stroked)
        ctx.setFillColor(gray: 1, alpha: CGFloat(color.value) / 255)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Mirror the canvas left to right, padding included.
    ///
    /// Several powerline separators are the mirror image of another, and
    /// drawing then flipping is both less code and guaranteed symmetric.
    func flipHorizontal() {
        let count = width * height
        let clone = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { clone.deallocate() }
        clone.update(from: buffer, count: count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                buffer[row + x] = clone[row + width - x - 1]
            }
        }
        swap(&clipLeft, &clipRight)
    }

    /// Mirror the canvas top to bottom, padding included.
    func flipVertical() {
        let count = width * height
        let clone = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { clone.deallocate() }
        clone.update(from: buffer, count: count)
        for y in 0..<height {
            for x in 0..<width {
                buffer[y * width + x] = clone[(height - y - 1) * width + x]
            }
        }
        swap(&clipTop, &clipBottom)
    }

    /// Invert every pixel. Used by glyphs defined as the negative of another.
    func invert() {
        for i in 0..<(width * height) {
            buffer[i] = 255 - buffer[i]
        }
    }

    // MARK: - Atlas

    /// Trim fully transparent rows and columns, reserve a region and copy the
    /// remainder in. Trimming matters: a bar cursor is one pixel of ink in a
    /// cell-sized canvas, and packing the whole canvas would waste the atlas.
    func writeAtlas(to atlas: Atlas) throws -> AtlasRegion {
        precondition(atlas.format == .grayscale)
        trim()

        let regionWidth = max(0, width - clipLeft - clipRight)
        let regionHeight = max(0, height - clipTop - clipBottom)

        let region = try atlas.reserve(
            width: UInt32(regionWidth), height: UInt32(regionHeight))

        if region.width > 0 && region.height > 0 {
            atlas.set(
                region,
                from: buffer,
                sourceWidth: UInt32(width),
                sourceX: UInt32(clipLeft),
                sourceY: UInt32(clipTop))
        }
        return region
    }

    /// Grow the clip margins inward over any fully transparent edge.
    private func trim() {
        top: while clipTop < height - clipBottom {
            let y = clipTop
            for x in clipLeft..<(width - clipRight) where buffer[y * width + x] != 0 {
                break top
            }
            clipTop += 1
        }

        bottom: while clipBottom < height - clipTop {
            let y = height - clipBottom - 1
            for x in clipLeft..<(width - clipRight) where buffer[y * width + x] != 0 {
                break bottom
            }
            clipBottom += 1
        }

        left: while clipLeft < width - clipRight {
            let x = clipLeft
            for y in clipTop..<(height - clipBottom) where buffer[y * width + x] != 0 {
                break left
            }
            clipLeft += 1
        }

        right: while clipRight < width - clipLeft {
            let x = width - clipRight - 1
            for y in clipTop..<(height - clipBottom) where buffer[y * width + x] != 0 {
                break right
            }
            clipRight += 1
        }
    }
}
