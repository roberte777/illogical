//  SpriteBox.swift
//  Box Drawing | U+2500...U+257F
//  https://en.wikipedia.org/wiki/Box_Drawing
//
//  ─━│┃┄┅┆┇┈┉┊┋┌┍┎┏┐┑┒┓└┕┖┗┘┙┚┛├┝┞┟
//  ┠┡┢┣┤┥┦┧┨┩┪┫┬┭┮┯┰┱┲┳┴┵┶┷┸┹┺┻┼┽┾┿
//  ╀╁╂╃╄╅╆╇╈╉╊╋╌╍╎╏═║╒╓╔╕╖╗╘╙╚╛╜╝╞╟
//  ╠╡╢╣╤╥╦╧╨╩╪╫╬╭╮╯╰╱╲╳╴╵╶╷╸╹╺╻╼╽╾╿
//
//  Ported from libghostty's `src/font/sprite/draw/box.zig`.
//
//  We draw these ourselves rather than using the font's own glyphs because a
//  box drawing character has to meet its neighbours exactly. Font glyphs are
//  laid out for a nominal advance width and get positioned with rounding, so
//  a vertical line in one cell lands a pixel off the one below it and a table
//  border comes out visibly ragged. Drawing to the pixel grid directly is the
//  only way to get seams that actually close.
//
//  109 of the 128 codepoints are "intersection" characters: some combination
//  of light, heavy or double strokes reaching from each edge to the centre.
//  Those live in a packed table. The other 19 are dashes, arcs and diagonals.

import CoreGraphics
import Foundation

enum SpriteBox {
    static let range: ClosedRange<UInt32> = 0x2500...0x257F

    /// Stroke weight of each arm of an intersection character.
    enum LineStyle: UInt8 {
        case none = 0
        case light = 1
        case heavy = 2
        case double = 3
    }

    /// The four arms of an intersection character, two bits each:
    /// up, right, down, left from the low bits up. Matches libghostty's
    /// packed `Lines` struct.
    struct Lines {
        var up: LineStyle = .none
        var right: LineStyle = .none
        var down: LineStyle = .none
        var left: LineStyle = .none

        init(packed: UInt8) {
            up = LineStyle(rawValue: packed & 0x3) ?? .none
            right = LineStyle(rawValue: (packed >> 2) & 0x3) ?? .none
            down = LineStyle(rawValue: (packed >> 4) & 0x3) ?? .none
            left = LineStyle(rawValue: (packed >> 6) & 0x3) ?? .none
        }
    }

    /// Packed `Lines` for U+2500 through U+257F, transpiled from the switch
    /// in libghostty's box.zig.
    ///
    /// The nineteen codepoints that aren't intersection characters — dashes,
    /// arcs, diagonals — are matched by `draw` before it reaches this table,
    /// and hold zero here. There is deliberately no sentinel value: every one
    /// of the 256 bit patterns is a legal intersection, and U+256C (all four
    /// arms double) really is 0x00.
    private static let lineTable: [UInt8] = [
        0x44, 0x88, 0x11, 0x22, 0x00, 0x00, 0x00, 0x00,  // U+2500
        0x00, 0x00, 0x00, 0x00, 0x14, 0x18, 0x24, 0x28,  // U+2508
        0x50, 0x90, 0x60, 0xA0, 0x05, 0x09, 0x06, 0x0A,  // U+2510
        0x41, 0x81, 0x42, 0x82, 0x15, 0x19, 0x16, 0x25,  // U+2518
        0x26, 0x1A, 0x29, 0x2A, 0x51, 0x91, 0x52, 0x61,  // U+2520
        0x62, 0x92, 0xA1, 0xA2, 0x54, 0x94, 0x58, 0x98,  // U+2528
        0x64, 0xA4, 0x68, 0xA8, 0x45, 0x85, 0x49, 0x89,  // U+2530
        0x46, 0x86, 0x4A, 0x8A, 0x55, 0x95, 0x59, 0x99,  // U+2538
        0x56, 0x65, 0x66, 0x96, 0x5A, 0xA5, 0x69, 0x9A,  // U+2540
        0xA9, 0xA6, 0x6A, 0xAA, 0x00, 0x00, 0x00, 0x00,  // U+2548
        0xCC, 0x33, 0x1C, 0x34, 0x3C, 0xD0, 0x70, 0xF0,  // U+2550
        0x0D, 0x07, 0x0F, 0xC1, 0x43, 0xC3, 0x1D, 0x37,  // U+2558
        0x3F, 0xD1, 0x73, 0xF3, 0xDC, 0x74, 0xFC, 0xCD,  // U+2560
        0x47, 0xCF, 0xDD, 0x77, 0xFF, 0x00, 0x00, 0x00,  // U+2568
        0x00, 0x00, 0x00, 0x00, 0x40, 0x01, 0x04, 0x10,  // U+2570
        0x80, 0x02, 0x08, 0x20, 0x48, 0x21, 0x84, 0x12,  // U+2578
    ]

    static func draw(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        let light = SpriteThickness.light.height(m.boxThickness)
        let heavy = SpriteThickness.heavy.height(m.boxThickness)

        switch cp {
        // Dashes. The gap is at least 4px for the triple/quadruple dashes so
        // they stay legible at small sizes.
        case 0x2504: dashHorizontal(m, canvas, 3, light, max(4, light))
        case 0x2505: dashHorizontal(m, canvas, 3, heavy, max(4, light))
        case 0x2506: dashVertical(m, canvas, 3, light, max(4, light))
        case 0x2507: dashVertical(m, canvas, 3, heavy, max(4, light))
        case 0x2508: dashHorizontal(m, canvas, 4, light, max(4, light))
        case 0x2509: dashHorizontal(m, canvas, 4, heavy, max(4, light))
        case 0x250A: dashVertical(m, canvas, 4, light, max(4, light))
        case 0x250B: dashVertical(m, canvas, 4, heavy, max(4, light))
        case 0x254C: dashHorizontal(m, canvas, 2, light, light)
        case 0x254D: dashHorizontal(m, canvas, 2, heavy, heavy)
        case 0x254E: dashVertical(m, canvas, 2, light, heavy)
        case 0x254F: dashVertical(m, canvas, 2, heavy, heavy)

        // Rounded corners.
        case 0x256D: arc(m, canvas, .br, .light)
        case 0x256E: arc(m, canvas, .bl, .light)
        case 0x256F: arc(m, canvas, .tl, .light)
        case 0x2570: arc(m, canvas, .tr, .light)

        // Diagonals.
        case 0x2571: lightDiagonalUpperRightToLowerLeft(m, canvas)
        case 0x2572: lightDiagonalUpperLeftToLowerRight(m, canvas)
        case 0x2573:
            lightDiagonalUpperRightToLowerLeft(m, canvas)
            lightDiagonalUpperLeftToLowerRight(m, canvas)

        default:
            guard range.contains(cp) else { return }
            linesChar(m, canvas, Lines(packed: lineTable[Int(cp - 0x2500)]))
        }
    }

    // MARK: - Intersections

    /// Draw an intersection character.
    ///
    /// Each arm runs from its edge to a stop point near the centre. Where the
    /// arm stops depends on the *other* arms: a light vertical meeting a
    /// heavy horizontal has to stop at the heavy stroke's edge, and a double
    /// stroke has to leave the gap between its two lines open or closed
    /// depending on what it meets. That is what the four stop calculations
    /// below work out.
    static func linesChar(_ m: GridMetrics, _ canvas: SpriteCanvas, _ lines: Lines) {
        let lightPx = SpriteThickness.light.height(m.boxThickness)
        let heavyPx = SpriteThickness.heavy.height(m.boxThickness)

        let cellW = Int(m.cellWidth)
        let cellH = Int(m.cellHeight)

        // Horizontal stroke extents.
        let hLightTop = (cellH - min(cellH, Int(lightPx))) / 2
        let hLightBottom = hLightTop + Int(lightPx)
        let hHeavyTop = (cellH - min(cellH, Int(heavyPx))) / 2
        let hHeavyBottom = hHeavyTop + Int(heavyPx)
        // Outer edges of a doubled horizontal; the inner edges are the light
        // stroke's own edges.
        let hDoubleTop = hLightTop - Int(lightPx)
        let hDoubleBottom = hLightBottom + Int(lightPx)

        // Vertical stroke extents.
        let vLightLeft = (cellW - min(cellW, Int(lightPx))) / 2
        let vLightRight = vLightLeft + Int(lightPx)
        let vHeavyLeft = (cellW - min(cellW, Int(heavyPx))) / 2
        let vHeavyRight = vHeavyLeft + Int(heavyPx)
        let vDoubleLeft = vLightLeft - Int(lightPx)
        let vDoubleRight = vLightRight + Int(lightPx)

        // Where the up arm stops.
        let upBottom: Int = {
            if lines.left == .heavy || lines.right == .heavy { return hHeavyBottom }
            if lines.left != lines.right || lines.down == lines.up {
                return (lines.left == .double || lines.right == .double)
                    ? hDoubleBottom : hLightBottom
            }
            if lines.left == .none && lines.right == .none { return hLightBottom }
            return hLightTop
        }()

        // Where the down arm starts.
        let downTop: Int = {
            if lines.left == .heavy || lines.right == .heavy { return hHeavyTop }
            if lines.left != lines.right || lines.up == lines.down {
                return (lines.left == .double || lines.right == .double)
                    ? hDoubleTop : hLightTop
            }
            if lines.left == .none && lines.right == .none { return hLightTop }
            return hLightBottom
        }()

        // Where the left arm stops.
        let leftRight: Int = {
            if lines.up == .heavy || lines.down == .heavy { return vHeavyRight }
            if lines.up != lines.down || lines.left == lines.right {
                return (lines.up == .double || lines.down == .double)
                    ? vDoubleRight : vLightRight
            }
            if lines.up == .none && lines.down == .none { return vLightRight }
            return vLightLeft
        }()

        // Where the right arm starts.
        let rightLeft: Int = {
            if lines.up == .heavy || lines.down == .heavy { return vHeavyLeft }
            if lines.up != lines.down || lines.right == lines.left {
                return (lines.up == .double || lines.down == .double)
                    ? vDoubleLeft : vLightLeft
            }
            if lines.up == .none && lines.down == .none { return vLightLeft }
            return vLightRight
        }()

        switch lines.up {
        case .none: break
        case .light: canvas.box(vLightLeft, 0, vLightRight, upBottom, .on)
        case .heavy: canvas.box(vHeavyLeft, 0, vHeavyRight, upBottom, .on)
        case .double:
            // A double arm meeting another double turns the corner, so its
            // two strokes stop at different places.
            let leftBottom = lines.left == .double ? hLightTop : upBottom
            let rightBottom = lines.right == .double ? hLightTop : upBottom
            canvas.box(vDoubleLeft, 0, vLightLeft, leftBottom, .on)
            canvas.box(vLightRight, 0, vDoubleRight, rightBottom, .on)
        }

        switch lines.right {
        case .none: break
        case .light: canvas.box(rightLeft, hLightTop, cellW, hLightBottom, .on)
        case .heavy: canvas.box(rightLeft, hHeavyTop, cellW, hHeavyBottom, .on)
        case .double:
            let topLeft = lines.up == .double ? vLightRight : rightLeft
            let bottomLeft = lines.down == .double ? vLightRight : rightLeft
            canvas.box(topLeft, hDoubleTop, cellW, hLightTop, .on)
            canvas.box(bottomLeft, hLightBottom, cellW, hDoubleBottom, .on)
        }

        switch lines.down {
        case .none: break
        case .light: canvas.box(vLightLeft, downTop, vLightRight, cellH, .on)
        case .heavy: canvas.box(vHeavyLeft, downTop, vHeavyRight, cellH, .on)
        case .double:
            let leftTop = lines.left == .double ? hLightBottom : downTop
            let rightTop = lines.right == .double ? hLightBottom : downTop
            canvas.box(vDoubleLeft, leftTop, vLightLeft, cellH, .on)
            canvas.box(vLightRight, rightTop, vDoubleRight, cellH, .on)
        }

        switch lines.left {
        case .none: break
        case .light: canvas.box(0, hLightTop, leftRight, hLightBottom, .on)
        case .heavy: canvas.box(0, hHeavyTop, leftRight, hHeavyBottom, .on)
        case .double:
            let topRight = lines.up == .double ? vLightLeft : leftRight
            let bottomRight = lines.down == .double ? vLightLeft : leftRight
            canvas.box(0, hDoubleTop, topRight, hLightTop, .on)
            canvas.box(0, hLightBottom, bottomRight, hDoubleBottom, .on)
        }
    }

    // MARK: - Diagonals

    static func lightDiagonalUpperRightToLowerLeft(_ m: GridMetrics, _ canvas: SpriteCanvas) {
        let w = Double(m.cellWidth)
        let h = Double(m.cellHeight)
        // Overshoot the corners slightly so adjacent cells join, while
        // keeping the slope exact.
        let sx = min(1.0, w / h)
        let sy = min(1.0, h / w)
        canvas.line(
            from: SpritePoint(w + 0.5 * sx, -0.5 * sy),
            to: SpritePoint(-0.5 * sx, h + 0.5 * sy),
            thickness: Double(SpriteThickness.light.height(m.boxThickness)), .on)
    }

    static func lightDiagonalUpperLeftToLowerRight(_ m: GridMetrics, _ canvas: SpriteCanvas) {
        let w = Double(m.cellWidth)
        let h = Double(m.cellHeight)
        let sx = min(1.0, w / h)
        let sy = min(1.0, h / w)
        canvas.line(
            from: SpritePoint(-0.5 * sx, -0.5 * sy),
            to: SpritePoint(w + 0.5 * sx, h + 0.5 * sy),
            thickness: Double(SpriteThickness.light.height(m.boxThickness)), .on)
    }

    // MARK: - Arcs

    /// A rounded corner: a straight run in from one edge, a curve through the
    /// centre, and a straight run out to the perpendicular edge.
    static func arc(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ corner: SpriteCorner,
        _ thickness: SpriteThickness
    ) {
        let thickPx = thickness.height(m.boxThickness)
        let w = Double(m.cellWidth)
        let h = Double(m.cellHeight)
        let t = Double(thickPx)
        let cx = Double((m.cellWidth - min(m.cellWidth, thickPx)) / 2) + t / 2
        let cy = Double((m.cellHeight - min(m.cellHeight, thickPx)) / 2) + t / 2

        let r = min(w, h) / 2
        // How far from the centre the control points sit.
        let s = 0.25

        canvas.strokePath(.on, lineWidth: t, lineCap: .butt) { ctx in
            switch corner {
            case .tl:
                ctx.move(to: CGPoint(x: cx, y: 0))
                ctx.addLine(to: CGPoint(x: cx, y: cy - r))
                ctx.addCurve(
                    to: CGPoint(x: cx - r, y: cy),
                    control1: CGPoint(x: cx, y: cy - s * r),
                    control2: CGPoint(x: cx - s * r, y: cy))
                ctx.addLine(to: CGPoint(x: 0, y: cy))
            case .tr:
                ctx.move(to: CGPoint(x: cx, y: 0))
                ctx.addLine(to: CGPoint(x: cx, y: cy - r))
                ctx.addCurve(
                    to: CGPoint(x: cx + r, y: cy),
                    control1: CGPoint(x: cx, y: cy - s * r),
                    control2: CGPoint(x: cx + s * r, y: cy))
                ctx.addLine(to: CGPoint(x: w, y: cy))
            case .bl:
                ctx.move(to: CGPoint(x: cx, y: h))
                ctx.addLine(to: CGPoint(x: cx, y: cy + r))
                ctx.addCurve(
                    to: CGPoint(x: cx - r, y: cy),
                    control1: CGPoint(x: cx, y: cy + s * r),
                    control2: CGPoint(x: cx - s * r, y: cy))
                ctx.addLine(to: CGPoint(x: 0, y: cy))
            case .br:
                ctx.move(to: CGPoint(x: cx, y: h))
                ctx.addLine(to: CGPoint(x: cx, y: cy + r))
                ctx.addCurve(
                    to: CGPoint(x: cx + r, y: cy),
                    control1: CGPoint(x: cx, y: cy + s * r),
                    control2: CGPoint(x: cx + s * r, y: cy))
                ctx.addLine(to: CGPoint(x: w, y: cy))
            }
        }
    }

    // MARK: - Dashes

    /// A horizontal dashed line that tiles cleanly.
    ///
    ///     +------------+
    ///     |            |
    ///     | --  --  -- |
    ///     |            |
    ///     +------------+
    ///
    /// Half-sized gaps at the left and right edges, so that abutting cells
    /// produce one line with even gaps rather than a double-width gap at
    /// every boundary.
    static func dashHorizontal(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ count: Int,
        _ thickPx: UInt32, _ desiredGap: UInt32
    ) {
        precondition(count >= 2 && count <= 4)

        // N dashes have N-1 gaps between them plus two half gaps at the
        // edges, so N gaps in total.
        let gapCount = count

        // Without a pixel each for every dash and gap we can't draw this at
        // all, so fall back to a solid line.
        if Int(m.cellWidth) < count + gapCount {
            SpriteDraw.hlineMiddle(m, canvas, .light)
            return
        }

        // Gaps must never exceed half the cell or the dashes get too small
        // to read.
        let gapWidth = Int(min(desiredGap, m.cellWidth / UInt32(2 * count)))
        let totalGapWidth = gapCount * gapWidth
        let totalDashWidth = Int(m.cellWidth) - totalGapWidth
        let dashWidth = totalDashWidth / count
        var extra = totalDashWidth % count

        let y = Int((m.cellHeight - min(m.cellHeight, thickPx)) / 2)

        // Start half a gap in, to centre the pattern.
        var x = gapWidth / 2

        for _ in 0..<count {
            var x1 = x + dashWidth
            // Spend the remainder on dash widths rather than gaps: a 1px
            // difference in a dash is far less visible than in a gap.
            if extra > 0 {
                extra -= 1
                x1 += 1
            }
            SpriteDraw.hline(canvas, x1: x, x2: x1, y: y, thickness: thickPx)
            x = x1 + gapWidth
        }
    }

    /// A vertical dashed line that tiles cleanly.
    ///
    /// Unlike the horizontal case this puts one whole gap at the bottom
    /// rather than half a gap at each end. Vertical centring matters much
    /// less visually, and a whole gap joins to solid characters without
    /// leaving a visible half gap.
    static func dashVertical(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ count: Int,
        _ thickPx: UInt32, _ desiredGap: UInt32
    ) {
        precondition(count >= 2 && count <= 4)

        let gapCount = count

        if Int(m.cellHeight) < count + gapCount {
            SpriteDraw.vlineMiddle(m, canvas, .light)
            return
        }

        let gapHeight = Int(min(desiredGap, m.cellHeight / UInt32(2 * count)))
        let totalGapHeight = gapCount * gapHeight
        let totalDashHeight = Int(m.cellHeight) - totalGapHeight
        let dashHeight = totalDashHeight / count
        var extra = totalDashHeight % count

        let x = Int((m.cellWidth - min(m.cellWidth, thickPx)) / 2)
        var y = 0

        for _ in 0..<count {
            var y1 = y + dashHeight
            if extra > 0 {
                extra -= 1
                y1 += 1
            }
            SpriteDraw.vline(canvas, y1: y, y2: y1, x: x, thickness: thickPx)
            y = y1 + gapHeight
        }
    }
}
