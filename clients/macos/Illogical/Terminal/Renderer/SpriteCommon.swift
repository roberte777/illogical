//  SpriteCommon.swift
//  Shared vocabulary for the sprite glyph drawing code.
//
//  Ported from libghostty's `src/font/sprite/draw/common.zig`.
//
//  The important type here is `Fraction`. Box drawing is defined in terms of
//  fractions of the cell — "a line at one third across" — and turning those
//  into integer pixels naively produces glyphs that don't line up between
//  adjacent cells. `min` and `max` round from opposite ends so that the two
//  halves of a split cell always add back up to the whole.

import Foundation

/// Line weight, as the Unicode box drawing block distinguishes them.
enum SpriteThickness {
    case superLight
    case light
    case heavy

    /// Actual pixel height given the metrics' base box thickness.
    func height(_ base: UInt32) -> UInt32 {
        switch self {
        case .superLight: return max(base / 2, 1)
        case .light: return base
        case .heavy: return base * 2
        }
    }
}

/// Shade levels for the shade blocks (U+2591..U+2593).
enum SpriteShade: UInt8 {
    case off = 0x00
    case light = 0x40
    case medium = 0x80
    case dark = 0xC0
    case on = 0xFF

    var color: SpriteColor { SpriteColor(value: rawValue) }
}

/// Which quadrants of a cell a feature occupies.
struct SpriteQuads {
    var tl = false
    var tr = false
    var bl = false
    var br = false
}

enum SpriteCorner {
    case tl, tr, bl, br
}

enum SpriteEdge {
    case top, left, bottom, right
}

/// Where a figure sits within its cell.
struct SpriteAlignment {
    enum Horizontal { case left, right, center }
    enum Vertical { case top, bottom, middle }

    var horizontal: Horizontal = .center
    var vertical: Vertical = .middle

    static let upper = SpriteAlignment(vertical: .top)
    static let lower = SpriteAlignment(vertical: .bottom)
    static let left = SpriteAlignment(horizontal: .left)
    static let right = SpriteAlignment(horizontal: .right)
    static let center = SpriteAlignment()

    static let upperLeft = SpriteAlignment(horizontal: .left, vertical: .top)
    static let upperRight = SpriteAlignment(horizontal: .right, vertical: .top)
    static let lowerLeft = SpriteAlignment(horizontal: .left, vertical: .bottom)
    static let lowerRight = SpriteAlignment(horizontal: .right, vertical: .bottom)
}

/// A position across the cell, as a fraction of its width or height.
enum SpriteFraction {
    case zero
    case oneEighth
    case oneQuarter
    case oneThird
    case threeEighths
    case half
    case fiveEighths
    case twoThirds
    case threeQuarters
    case sevenEighths
    case one

    var value: Double {
        switch self {
        case .zero: return 0.0
        case .oneEighth: return 0.125
        case .oneQuarter: return 0.25
        case .oneThird: return 1.0 / 3.0
        case .threeEighths: return 0.375
        case .half: return 0.5
        case .fiveEighths: return 0.625
        case .twoThirds: return 2.0 / 3.0
        case .threeQuarters: return 0.75
        case .sevenEighths: return 0.875
        case .one: return 1.0
        }
    }

    /// Indexable as `eighths[i]` for `i/8`.
    static let eighths: [SpriteFraction] = [
        .zero, .oneEighth, .oneQuarter, .threeEighths, .half,
        .fiveEighths, .threeQuarters, .sevenEighths, .one,
    ]
    /// Indexable as `quarters[i]` for `i/4`.
    static let quarters: [SpriteFraction] = [
        .zero, .oneQuarter, .half, .threeQuarters, .one,
    ]
    /// Indexable as `thirds[i]` for `i/3`.
    static let thirds: [SpriteFraction] = [.zero, .oneThird, .twoThirds, .one]
    /// Indexable as `halves[i]` for `i/2`.
    static let halves: [SpriteFraction] = [.zero, .half, .one]

    /// Pixel position when used as the *min* (left or top) edge of a block.
    ///
    /// Deliberately different from `max`: we round the complementary fraction
    /// taken from the far end. For a size of 7, the half line gives
    /// `7 - round(0.5 * 7) = 3` here and `round(0.5 * 7) = 4` from `max`, so
    /// `start -> half` and `half -> end` are both 4px (0->4 and 3->7) and the
    /// two halves visually match instead of being 3 and 4.
    func min(_ size: some BinaryInteger) -> Int {
        let s = Double(size)
        return Int(s - ((1.0 - value) * s).rounded())
    }

    /// Pixel position when used as the *max* (right or bottom) edge.
    func max(_ size: some BinaryInteger) -> Int {
        let s = Double(size)
        return Int((value * s).rounded())
    }

    /// The unrounded position. For path drawing, where pixel alignment is
    /// neither achievable nor wanted.
    func float(_ size: some BinaryInteger) -> Double {
        value * Double(size)
    }
}

/// Helpers shared by the box, block and legacy-computing draw code.
enum SpriteDraw {
    /// Fill the section of the cell bounded by two pairs of fraction lines.
    static func fill(
        _ metrics: GridMetrics,
        _ canvas: SpriteCanvas,
        _ x0: SpriteFraction, _ x1: SpriteFraction,
        _ y0: SpriteFraction, _ y1: SpriteFraction
    ) {
        canvas.box(
            x0.min(metrics.cellWidth),
            y0.min(metrics.cellHeight),
            x1.max(metrics.cellWidth),
            y1.max(metrics.cellHeight),
            .on)
    }

    /// A vertical line down the middle of the cell.
    static func vlineMiddle(
        _ metrics: GridMetrics, _ canvas: SpriteCanvas, _ thickness: SpriteThickness
    ) {
        let thick = thickness.height(metrics.boxThickness)
        vline(
            canvas,
            y1: 0,
            y2: Int(metrics.cellHeight),
            x: Int((metrics.cellWidth &- Swift.min(metrics.cellWidth, thick)) / 2),
            thickness: thick)
    }

    /// A horizontal line across the middle of the cell.
    static func hlineMiddle(
        _ metrics: GridMetrics, _ canvas: SpriteCanvas, _ thickness: SpriteThickness
    ) {
        let thick = thickness.height(metrics.boxThickness)
        hline(
            canvas,
            x1: 0,
            x2: Int(metrics.cellWidth),
            y: Int((metrics.cellHeight &- Swift.min(metrics.cellHeight, thick)) / 2),
            thickness: thick)
    }

    /// Vertical line with its left edge at `x`, spanning `y1` to `y2`.
    static func vline(
        _ canvas: SpriteCanvas, y1: Int, y2: Int, x: Int, thickness: UInt32
    ) {
        canvas.box(x, y1, x + Int(thickness), y2, .on)
    }

    /// Horizontal line with its top edge at `y`, spanning `x1` to `x2`.
    static func hline(
        _ canvas: SpriteCanvas, x1: Int, x2: Int, y: Int, thickness: UInt32
    ) {
        canvas.box(x1, y, x2, y + Int(thickness), .on)
    }
}
