//  SpriteBlock.swift
//  Block Elements | U+2580...U+259F
//  https://en.wikipedia.org/wiki/Block_Elements
//
//  ▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏▐░▒▓▔▕▖▗▘▙▚▛▜▝▞▟
//
//  Ported from libghostty's `src/font/sprite/draw/block.zig`.
//
//  Blocks have to be exact for the same reason box drawing does: a column of
//  half blocks is a solid bar only if every one of them lands on the same
//  pixel boundary. The shade blocks (░▒▓) are a flat alpha over the whole
//  cell rather than a dither pattern, which is what makes them tile without
//  moiré.
//
//  Braille Patterns | U+2800...U+28FF are here too, since they are the same
//  kind of glyph: a fixed geometric layout computed from the cell size.

import Foundation

enum SpriteBlock {
    static let range: ClosedRange<UInt32> = 0x2580...0x259F

    private static let oneEighth = 0.125
    private static let oneQuarter = 0.25
    private static let threeEighths = 0.375
    private static let half = 0.5
    private static let fiveEighths = 0.625
    private static let threeQuarters = 0.75
    private static let sevenEighths = 0.875

    static func draw(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        switch cp {
        case 0x2580: block(m, canvas, .upper, 1, half)  // ▀ upper half
        case 0x2581: block(m, canvas, .lower, 1, oneEighth)  // ▁
        case 0x2582: block(m, canvas, .lower, 1, oneQuarter)  // ▂
        case 0x2583: block(m, canvas, .lower, 1, threeEighths)  // ▃
        case 0x2584: block(m, canvas, .lower, 1, half)  // ▄
        case 0x2585: block(m, canvas, .lower, 1, fiveEighths)  // ▅
        case 0x2586: block(m, canvas, .lower, 1, threeQuarters)  // ▆
        case 0x2587: block(m, canvas, .lower, 1, sevenEighths)  // ▇
        case 0x2588: fullBlockShade(m, canvas, .on)  // █ full
        case 0x2589: block(m, canvas, .left, sevenEighths, 1)  // ▉
        case 0x258A: block(m, canvas, .left, threeQuarters, 1)  // ▊
        case 0x258B: block(m, canvas, .left, fiveEighths, 1)  // ▋
        case 0x258C: block(m, canvas, .left, half, 1)  // ▌
        case 0x258D: block(m, canvas, .left, threeEighths, 1)  // ▍
        case 0x258E: block(m, canvas, .left, oneQuarter, 1)  // ▎
        case 0x258F: block(m, canvas, .left, oneEighth, 1)  // ▏

        case 0x2590: block(m, canvas, .right, half, 1)  // ▐
        case 0x2591: fullBlockShade(m, canvas, .light)  // ░
        case 0x2592: fullBlockShade(m, canvas, .medium)  // ▒
        case 0x2593: fullBlockShade(m, canvas, .dark)  // ▓
        case 0x2594: block(m, canvas, .upper, 1, oneEighth)  // ▔
        case 0x2595: block(m, canvas, .right, oneEighth, 1)  // ▕
        case 0x2596: quadrant(m, canvas, SpriteQuads(bl: true))  // ▖
        case 0x2597: quadrant(m, canvas, SpriteQuads(br: true))  // ▗
        case 0x2598: quadrant(m, canvas, SpriteQuads(tl: true))  // ▘
        case 0x2599: quadrant(m, canvas, SpriteQuads(tl: true, bl: true, br: true))  // ▙
        case 0x259A: quadrant(m, canvas, SpriteQuads(tl: true, br: true))  // ▚
        case 0x259B: quadrant(m, canvas, SpriteQuads(tl: true, tr: true, bl: true))  // ▛
        case 0x259C: quadrant(m, canvas, SpriteQuads(tl: true, tr: true, br: true))  // ▜
        case 0x259D: quadrant(m, canvas, SpriteQuads(tr: true))  // ▝
        case 0x259E: quadrant(m, canvas, SpriteQuads(tr: true, bl: true))  // ▞
        case 0x259F: quadrant(m, canvas, SpriteQuads(tr: true, bl: true, br: true))  // ▟
        default: break
        }
    }

    /// A solid block covering `width` x `height` of the cell, aligned as
    /// requested.
    static func block(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ alignment: SpriteAlignment,
        _ width: Double, _ height: Double
    ) {
        blockShade(m, canvas, alignment, width, height, .on)
    }

    static func blockShade(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ alignment: SpriteAlignment,
        _ width: Double, _ height: Double, _ shade: SpriteShade
    ) {
        let w = Int((Double(m.cellWidth) * width).rounded())
        let h = Int((Double(m.cellHeight) * height).rounded())

        let x: Int
        switch alignment.horizontal {
        case .left: x = 0
        case .right: x = Int(m.cellWidth) - w
        case .center: x = (Int(m.cellWidth) - w) / 2
        }
        let y: Int
        switch alignment.vertical {
        case .top: y = 0
        case .bottom: y = Int(m.cellHeight) - h
        case .middle: y = (Int(m.cellHeight) - h) / 2
        }

        canvas.rect(x: x, y: y, width: w, height: h, shade.color)
    }

    static func fullBlockShade(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ shade: SpriteShade
    ) {
        canvas.box(0, 0, Int(m.cellWidth), Int(m.cellHeight), shade.color)
    }

    private static func quadrant(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ quads: SpriteQuads
    ) {
        if quads.tl { SpriteDraw.fill(m, canvas, .zero, .half, .zero, .half) }
        if quads.tr { SpriteDraw.fill(m, canvas, .half, .one, .zero, .half) }
        if quads.bl { SpriteDraw.fill(m, canvas, .zero, .half, .half, .one) }
        if quads.br { SpriteDraw.fill(m, canvas, .half, .one, .half, .one) }
    }
}

enum SpriteBraille {
    static let range: ClosedRange<UInt32> = 0x2800...0x28FF

    /// A braille cell is 2x4 dots. The low 8 bits of the codepoint are the
    /// dot pattern, in this order:
    ///
    ///     [t]op    - .   .
    ///     [u]pper  - .   .
    ///     [l]ower  - .   .
    ///     [b]ottom - .   .
    ///                |   |
    ///              [l]eft, [r]ight
    private struct Pattern {
        let bits: UInt8
        var tl: Bool { bits & 0x01 != 0 }
        var ul: Bool { bits & 0x02 != 0 }
        var ll: Bool { bits & 0x04 != 0 }
        var tr: Bool { bits & 0x08 != 0 }
        var ur: Bool { bits & 0x10 != 0 }
        var lr: Bool { bits & 0x20 != 0 }
        var bl: Bool { bits & 0x40 != 0 }
        var br: Bool { bits & 0x80 != 0 }
    }

    /// Lay out eight dots in the cell.
    ///
    /// Braille is drawn at every terminal size, including ones where a cell
    /// is barely eight pixels tall, so the layout spends its leftover pixels
    /// in a fixed priority order: get a non-zero dot first, then a margin,
    /// then spacing, then bigger margins, and only then a fatter dot. That
    /// ordering is what keeps small sizes legible instead of degenerate.
    static func draw(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        var w = Int(min(width / 4, height / 8))
        var xSpacing = Int(width / 4)
        var ySpacing = Int(height / 8)
        var xMargin = xSpacing / 2
        var yMargin = ySpacing / 2

        var xLeft = Int(width) - 2 * xMargin - xSpacing - 2 * w
        var yLeft = Int(height) - 2 * yMargin - 3 * ySpacing - 4 * w

        // First, try hard to make the dot width non-zero.
        if xLeft >= 2 && yLeft >= 4 && w == 0 {
            w += 1
            xLeft -= 2
            yLeft -= 4
        }

        // Second, prefer a non-zero margin.
        if xLeft >= 2 && xMargin == 0 {
            xMargin = 1
            xLeft -= 2
        }
        if yLeft >= 2 && yMargin == 0 {
            yMargin = 1
            yLeft -= 2
        }

        // Third, increase spacing.
        if xLeft >= 1 {
            xSpacing += 1
            xLeft -= 1
        }
        if yLeft >= 3 {
            ySpacing += 1
            yLeft -= 3
        }

        // Fourth, grow the margins.
        if xLeft >= 2 {
            xMargin += 1
            xLeft -= 2
        }
        if yLeft >= 2 {
            yMargin += 1
            yLeft -= 2
        }

        // Last, a fatter dot.
        if xLeft >= 2 && yLeft >= 4 {
            w += 1
        }

        let x = [xMargin, xMargin + w + xSpacing]
        var y = [Int](repeating: 0, count: 4)
        y[0] = yMargin
        y[1] = y[0] + w + ySpacing
        y[2] = y[1] + w + ySpacing
        y[3] = y[2] + w + ySpacing

        let p = Pattern(bits: UInt8(truncatingIfNeeded: cp))

        if p.tl { canvas.box(x[0], y[0], x[0] + w, y[0] + w, .on) }
        if p.ul { canvas.box(x[0], y[1], x[0] + w, y[1] + w, .on) }
        if p.ll { canvas.box(x[0], y[2], x[0] + w, y[2] + w, .on) }
        if p.bl { canvas.box(x[0], y[3], x[0] + w, y[3] + w, .on) }
        if p.tr { canvas.box(x[1], y[0], x[1] + w, y[0] + w, .on) }
        if p.ur { canvas.box(x[1], y[1], x[1] + w, y[1] + w, .on) }
        if p.lr { canvas.box(x[1], y[2], x[1] + w, y[2] + w, .on) }
        if p.br { canvas.box(x[1], y[3], x[1] + w, y[3] + w, .on) }
    }
}
