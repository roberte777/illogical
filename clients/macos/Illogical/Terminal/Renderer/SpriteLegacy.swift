//  SpriteLegacy.swift
//  Symbols for Legacy Computing | U+1FB00...U+1FBEF
//  https://en.wikipedia.org/wiki/Symbols_for_Legacy_Computing
//
//  🬀🬁🬂🬃🬄🬅🬆🬇🬈🬉🬊🬋🬌🬍🬎🬏 🬼🬽🬾🬿🭀🭁🭂🭃🭄🭅🭆🭇🭈🭉🭊🭋
//  🭼🭽🭾🭿🮀🮁🮂🮃🮄🮅🮆🮇🮈🮉🮊🮋 🮌🮍🮎🮏🮐🮑🮒🮔🮕🮖🮗🮘🮙🮚🮛
//  🮜🮝🮞🮟🮠🮡🮢🮣🮤🮥🮦🮧🮨🮩🮪🮫🮬🮭🮮🮯 🯐🯑🯒🯓🯔🯕🯖🯗🯘🯙🯚🯛
//
//  Ported from libghostty's
//  `src/font/sprite/draw/symbols_for_legacy_computing.zig`.
//
//  This block is what tools like chafa and timg use to draw images in a
//  terminal: sextants and smooth mosaics give you three or four times the
//  vertical resolution of half blocks. That only works if every one of them
//  is exact to the pixel, which is precisely what a font can't promise and
//  drawing them ourselves can.

import CoreGraphics
import Foundation

enum SpriteLegacy {
    static func has(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x1FB00...0x1FB3B: return true  // sextants
        case 0x1FB3C...0x1FB67: return true  // smooth mosaics
        case 0x1FB68...0x1FB6F: return true  // edge triangles
        case 0x1FB70...0x1FB75: return true  // vertical eighths
        case 0x1FB76...0x1FB7B: return true  // horizontal eighths
        case 0x1FB7C...0x1FB97: return true  // block combinations and shades
        case 0x1FB98...0x1FB99: return true  // diagonal fills
        case 0x1FB9A...0x1FB9F: return true  // triangles and shaded corners
        case 0x1FBA0...0x1FBAE: return true  // corner diagonals
        case 0x1FBAF: return true
        case 0x1FBBD...0x1FBBF: return true
        case 0x1FBCE...0x1FBCF: return true
        case 0x1FBD0...0x1FBDF: return true  // cell diagonals
        case 0x1FBE0...0x1FBEF: return true  // circles and quarter blocks
        default: return false
        }
    }

    static func draw(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        switch cp {
        case 0x1FB00...0x1FB3B: sextant(cp, canvas, m)
        case 0x1FB3C...0x1FB67: smoothMosaic(cp, canvas, m)
        case 0x1FB68...0x1FB6F: edgeTriangles(cp, canvas, m)
        case 0x1FB70...0x1FB75: verticalEighth(cp, canvas, m)
        case 0x1FB76...0x1FB7B: horizontalEighth(cp, canvas, m)
        case 0x1FB7C...0x1FB97: blockCombination(cp, canvas, width, height, m)
        case 0x1FB98: diagonalFill(canvas, m, downRight: true)
        case 0x1FB99: diagonalFill(canvas, m, downRight: false)
        case 0x1FB9A...0x1FB9F: trianglesAndShades(cp, canvas, m)
        case 0x1FBA0...0x1FBAE: cornerDiagonals(cp, canvas, m)
        case 0x1FBAF:
            SpriteBox.linesChar(
                m, canvas, SpriteBox.Lines(packed: packLines(up: 2, right: 1, down: 2, left: 1)))
        case 0x1FBBD:
            SpriteBox.lightDiagonalUpperRightToLowerLeft(m, canvas)
            SpriteBox.lightDiagonalUpperLeftToLowerRight(m, canvas)
            canvas.invert()
            canvas.clipToCell()
        case 0x1FBBE:
            cornerDiagonalLines(m, canvas, SpriteQuads(br: true))
            canvas.invert()
            canvas.clipToCell()
        case 0x1FBBF:
            cornerDiagonalLines(
                m, canvas, SpriteQuads(tl: true, tr: true, bl: true, br: true))
            canvas.invert()
            canvas.clipToCell()
        case 0x1FBCE: SpriteBlock.block(m, canvas, .left, 2.0 / 3.0, 1)
        case 0x1FBCF: SpriteBlock.block(m, canvas, .left, 1.0 / 3.0, 1)
        case 0x1FBD0...0x1FBDF: cellDiagonals(cp, canvas, m)
        case 0x1FBE0...0x1FBEF: circlesAndQuarters(cp, canvas, m)
        default: break
        }
    }

    private static func packLines(up: UInt8, right: UInt8, down: UInt8, left: UInt8) -> UInt8 {
        up | (right << 2) | (down << 4) | (left << 6)
    }

    // MARK: - Sextants

    /// Six sub-cells in a 2x3 grid, one bit each.
    ///
    /// The codepoints skip the all-off and all-on patterns (those are SPACE
    /// and FULL BLOCK), which is what the `idx / 0x14` correction restores.
    private static func sextant(_ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics) {
        let idx = cp - 0x1FB00
        let bits = UInt8((idx + (idx / 0x14) + 1) & 0x3F)

        if bits & 0x01 != 0 { SpriteDraw.fill(m, canvas, .zero, .half, .zero, .oneThird) }
        if bits & 0x02 != 0 { SpriteDraw.fill(m, canvas, .half, .one, .zero, .oneThird) }
        if bits & 0x04 != 0 { SpriteDraw.fill(m, canvas, .zero, .half, .oneThird, .twoThirds) }
        if bits & 0x08 != 0 { SpriteDraw.fill(m, canvas, .half, .one, .oneThird, .twoThirds) }
        if bits & 0x10 != 0 { SpriteDraw.fill(m, canvas, .zero, .half, .twoThirds, .one) }
        if bits & 0x20 != 0 { SpriteDraw.fill(m, canvas, .half, .one, .twoThirds, .one) }
    }

    // MARK: - Smooth mosaics

    /// A polygon through up to ten fixed points around the cell edge.
    ///
    /// Ten bits, in the order the polygon visits them: tl, ul, ll, bl, bc,
    /// br, lr, ur, tr, tc. Transpiled from libghostty's hand-written table of
    /// ASCII-art patterns; there is no arithmetic relationship between the
    /// codepoints and the shapes, so a table is the only way.
    private static let mosaicTable: [UInt16] = [
        0x01C, 0x02C, 0x01A, 0x02A, 0x019, 0x32A, 0x12A, 0x32C,  // U+1FB3C
        0x12C, 0x328, 0x0AC, 0x070, 0x068, 0x0B0, 0x0A8, 0x130,  // U+1FB44
        0x2A9, 0x0A9, 0x269, 0x069, 0x229, 0x06A, 0x135, 0x125,  // U+1FB4C
        0x133, 0x123, 0x131, 0x203, 0x103, 0x205, 0x105, 0x209,  // U+1FB54
        0x185, 0x159, 0x149, 0x199, 0x189, 0x119, 0x380, 0x181,  // U+1FB5C
        0x340, 0x141, 0x320, 0x143,  // U+1FB64
    ]

    private static func smoothMosaic(_ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics) {
        let bits = mosaicTable[Int(cp - 0x1FB3C)]

        let top = 0.0
        let upper = SpriteFraction.oneThird.float(m.cellHeight)
        let lower = SpriteFraction.twoThirds.float(m.cellHeight)
        let bottom = Double(m.cellHeight)
        let left = 0.0
        let center = SpriteFraction.half.float(m.cellWidth)
        let right = Double(m.cellWidth)

        // The points in polygon order, so the path never self-intersects.
        let points: [(UInt16, Double, Double)] = [
            (1 << 0, left, top),  // tl
            (1 << 1, left, upper),  // ul
            (1 << 2, left, lower),  // ll
            (1 << 3, left, bottom),  // bl
            (1 << 4, center, bottom),  // bc
            (1 << 5, right, bottom),  // br
            (1 << 6, right, lower),  // lr
            (1 << 7, right, upper),  // ur
            (1 << 8, right, top),  // tr
            (1 << 9, center, top),  // tc
        ]

        canvas.fillPath(.on) { ctx in
            var started = false
            for (mask, x, y) in points where bits & mask != 0 {
                if started {
                    ctx.addLine(to: CGPoint(x: x, y: y))
                } else {
                    ctx.move(to: CGPoint(x: x, y: y))
                    started = true
                }
            }
            if started { ctx.closePath() }
        }
    }

    // MARK: - Triangles

    private static func edgeTriangles(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics
    ) {
        // The first four are the inverse of the second four.
        let inverted = cp <= 0x1FB6B
        let edge: SpriteEdge
        switch (cp - 0x1FB68) % 4 {
        case 0: edge = .left
        case 1: edge = .top
        case 2: edge = .right
        default: edge = .bottom
        }
        edgeTriangle(m, canvas, edge)
        if inverted {
            canvas.invert()
            canvas.clipToCell()
        }
    }

    /// A triangle from the centre of the cell out to one whole edge.
    private static func edgeTriangle(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ edge: SpriteEdge
    ) {
        let upper = 0.0
        let middle = (Double(m.cellHeight) / 2).rounded()
        let lower = Double(m.cellHeight)
        let left = 0.0
        let center = (Double(m.cellWidth) / 2).rounded()
        let right = Double(m.cellWidth)

        let p0: SpritePoint
        let p1: SpritePoint
        switch edge {
        case .top: (p0, p1) = (SpritePoint(right, upper), SpritePoint(left, upper))
        case .left: (p0, p1) = (SpritePoint(left, upper), SpritePoint(left, lower))
        case .bottom: (p0, p1) = (SpritePoint(left, lower), SpritePoint(right, lower))
        case .right: (p0, p1) = (SpritePoint(right, lower), SpritePoint(right, upper))
        }

        canvas.fillTriangle(SpritePoint(center, middle), p0, p1, .on)
    }

    private static func trianglesAndShades(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics
    ) {
        switch cp {
        case 0x1FB9A:
            edgeTriangle(m, canvas, .top)
            edgeTriangle(m, canvas, .bottom)
        case 0x1FB9B:
            edgeTriangle(m, canvas, .left)
            edgeTriangle(m, canvas, .right)
        case 0x1FB9C: SpriteGeometric.cornerTriangleShade(m, canvas, .tl, .medium)
        case 0x1FB9D: SpriteGeometric.cornerTriangleShade(m, canvas, .tr, .medium)
        case 0x1FB9E: SpriteGeometric.cornerTriangleShade(m, canvas, .br, .medium)
        case 0x1FB9F: SpriteGeometric.cornerTriangleShade(m, canvas, .bl, .medium)
        default: break
        }
    }

    // MARK: - Eighths

    private static func verticalEighth(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics
    ) {
        let n = Int(cp + 1 - 0x1FB70)
        SpriteDraw.fill(
            m, canvas, SpriteFraction.eighths[n], SpriteFraction.eighths[n + 1], .zero, .one)
    }

    private static func horizontalEighth(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics
    ) {
        let n = Int(cp + 1 - 0x1FB76)
        SpriteDraw.fill(
            m, canvas, .zero, .one, SpriteFraction.eighths[n], SpriteFraction.eighths[n + 1])
    }

    // MARK: - Block combinations

    private static func blockCombination(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        let oneEighth = 0.125
        let oneQuarter = 0.25
        let threeEighths = 0.375
        let half = 0.5
        let fiveEighths = 0.625
        let threeQuarters = 0.75
        let sevenEighths = 0.875

        switch cp {
        case 0x1FB7C:  // 🭼 left and lower one eighth
            SpriteBlock.block(m, canvas, .left, oneEighth, 1)
            SpriteBlock.block(m, canvas, .lower, 1, oneEighth)
        case 0x1FB7D:  // 🭽 left and upper one eighth
            SpriteBlock.block(m, canvas, .left, oneEighth, 1)
            SpriteBlock.block(m, canvas, .upper, 1, oneEighth)
        case 0x1FB7E:  // 🭾 right and upper one eighth
            SpriteBlock.block(m, canvas, .right, oneEighth, 1)
            SpriteBlock.block(m, canvas, .upper, 1, oneEighth)
        case 0x1FB7F:  // 🭿 right and lower one eighth
            SpriteBlock.block(m, canvas, .right, oneEighth, 1)
            SpriteBlock.block(m, canvas, .lower, 1, oneEighth)
        case 0x1FB80:  // 🮀 upper and lower one eighth
            SpriteBlock.block(m, canvas, .upper, 1, oneEighth)
            SpriteBlock.block(m, canvas, .lower, 1, oneEighth)
        case 0x1FB81:  // 🮁 horizontal one eighth 1358
            for n in [1, 3, 5, 8] {
                SpriteDraw.fill(
                    m, canvas, .zero, .one, SpriteFraction.eighths[n - 1],
                    SpriteFraction.eighths[n])
            }

        case 0x1FB82: SpriteBlock.block(m, canvas, .upper, 1, oneQuarter)
        case 0x1FB83: SpriteBlock.block(m, canvas, .upper, 1, threeEighths)
        case 0x1FB84: SpriteBlock.block(m, canvas, .upper, 1, fiveEighths)
        case 0x1FB85: SpriteBlock.block(m, canvas, .upper, 1, threeQuarters)
        case 0x1FB86: SpriteBlock.block(m, canvas, .upper, 1, sevenEighths)

        case 0x1FB87: SpriteBlock.block(m, canvas, .right, oneQuarter, 1)
        case 0x1FB88: SpriteBlock.block(m, canvas, .right, threeEighths, 1)
        case 0x1FB89: SpriteBlock.block(m, canvas, .right, fiveEighths, 1)
        case 0x1FB8A: SpriteBlock.block(m, canvas, .right, threeQuarters, 1)
        case 0x1FB8B: SpriteBlock.block(m, canvas, .right, sevenEighths, 1)

        case 0x1FB8C: SpriteBlock.blockShade(m, canvas, .left, half, 1, .medium)
        case 0x1FB8D: SpriteBlock.blockShade(m, canvas, .right, half, 1, .medium)
        case 0x1FB8E: SpriteBlock.blockShade(m, canvas, .upper, 1, half, .medium)
        case 0x1FB8F: SpriteBlock.blockShade(m, canvas, .lower, 1, half, .medium)

        case 0x1FB90: SpriteBlock.fullBlockShade(m, canvas, .medium)
        case 0x1FB91:
            SpriteBlock.fullBlockShade(m, canvas, .medium)
            SpriteBlock.block(m, canvas, .upper, 1, half)
        case 0x1FB92:
            SpriteBlock.fullBlockShade(m, canvas, .medium)
            SpriteBlock.block(m, canvas, .lower, 1, half)
        case 0x1FB93:
            // Unallocated hole in the block; an empty glyph is the honest
            // answer.
            break
        case 0x1FB94:
            SpriteBlock.fullBlockShade(m, canvas, .medium)
            SpriteBlock.block(m, canvas, .right, half, 1)
        case 0x1FB95: checkerboardFill(m, canvas, parity: 0)
        case 0x1FB96: checkerboardFill(m, canvas, parity: 1)
        case 0x1FB97:
            canvas.box(0, Int(height / 4), Int(width), Int(2 * height / 4), .on)
            canvas.box(0, Int(3 * height / 4), Int(width), Int(height), .on)
        default: break
        }
    }

    private static func checkerboardFill(
        _ m: GridMetrics, _ canvas: SpriteCanvas, parity: Int
    ) {
        let xSize = 4
        // Keep the squares roughly square rather than cell-shaped.
        let ySize = max(
            1, Int((4 * (Double(m.cellHeight) / Double(m.cellWidth))).rounded()))
        for x in 0..<xSize {
            let x0 = Int(m.cellWidth) * x / xSize
            let x1 = Int(m.cellWidth) * (x + 1) / xSize
            for y in 0..<ySize where (x + y) % 2 == parity {
                let y0 = Int(m.cellHeight) * y / ySize
                let y1 = Int(m.cellHeight) * (y + 1) / ySize
                canvas.rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0, .on)
            }
        }
    }

    // MARK: - Diagonals

    /// A field of parallel diagonal lines filling the cell, which tiles with
    /// its neighbours to make a continuous hatch.
    private static func diagonalFill(
        _ canvas: SpriteCanvas, _ m: GridMetrics, downRight: Bool
    ) {
        canvas.clipToCell()

        let thick = SpriteThickness.light.height(m.boxThickness)
        let lineCount = max(1, Int(m.cellWidth / (2 * max(1, thick))))

        let w = Double(m.cellWidth)
        let h = Double(m.cellHeight)
        let stride = (w / Double(lineCount)).rounded()

        for step in 0...(lineCount * 2) {
            let i = Double(step - lineCount)
            let offset = i * stride
            let topX = downRight ? offset : w + offset
            let bottomX = downRight ? w + offset : offset
            canvas.line(
                from: SpritePoint(topX, 0), to: SpritePoint(bottomX, h),
                thickness: Double(thick), .on)
        }
    }

    private static func cornerDiagonals(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics
    ) {
        let q: SpriteQuads
        switch cp {
        case 0x1FBA0: q = SpriteQuads(tl: true)
        case 0x1FBA1: q = SpriteQuads(tr: true)
        case 0x1FBA2: q = SpriteQuads(bl: true)
        case 0x1FBA3: q = SpriteQuads(br: true)
        case 0x1FBA4: q = SpriteQuads(tl: true, bl: true)
        case 0x1FBA5: q = SpriteQuads(tr: true, br: true)
        case 0x1FBA6: q = SpriteQuads(bl: true, br: true)
        case 0x1FBA7: q = SpriteQuads(tl: true, tr: true)
        case 0x1FBA8: q = SpriteQuads(tl: true, br: true)
        case 0x1FBA9: q = SpriteQuads(tr: true, bl: true)
        case 0x1FBAA: q = SpriteQuads(tr: true, bl: true, br: true)
        case 0x1FBAB: q = SpriteQuads(tl: true, bl: true, br: true)
        case 0x1FBAC: q = SpriteQuads(tl: true, tr: true, br: true)
        case 0x1FBAD: q = SpriteQuads(tl: true, tr: true, bl: true)
        case 0x1FBAE: q = SpriteQuads(tl: true, tr: true, bl: true, br: true)
        default: return
        }
        cornerDiagonalLines(m, canvas, q)
    }

    /// Lines from the midpoint of an edge to the midpoint of the next,
    /// cutting the named corners off.
    private static func cornerDiagonalLines(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ corners: SpriteQuads
    ) {
        let thick = Double(SpriteThickness.light.height(m.boxThickness))
        let w = Double(m.cellWidth)
        let h = Double(m.cellHeight)
        // Bias the centre up rather than down on odd sizes, so opposite
        // corners meet.
        let cx = Double(m.cellWidth / 2 + m.cellWidth % 2)
        let cy = Double(m.cellHeight / 2 + m.cellHeight % 2)

        if corners.tl {
            canvas.line(
                from: SpritePoint(cx, 0), to: SpritePoint(0, cy), thickness: thick, .on)
        }
        if corners.tr {
            canvas.line(
                from: SpritePoint(cx, 0), to: SpritePoint(w, cy), thickness: thick, .on)
        }
        if corners.bl {
            canvas.line(
                from: SpritePoint(cx, h), to: SpritePoint(0, cy), thickness: thick, .on)
        }
        if corners.br {
            canvas.line(
                from: SpritePoint(cx, h), to: SpritePoint(w, cy), thickness: thick, .on)
        }
    }

    private static func cellDiagonals(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics
    ) {
        typealias A = SpriteAlignment
        func line(_ from: A, _ to: A) { cellDiagonal(m, canvas, from, to) }

        switch cp {
        case 0x1FBD0: line(.right, .lowerLeft)
        case 0x1FBD1: line(.upperRight, .left)
        case 0x1FBD2: line(.upperLeft, .right)
        case 0x1FBD3: line(.left, .lowerRight)
        case 0x1FBD4: line(.upperLeft, .lower)
        case 0x1FBD5: line(.upper, .lowerRight)
        case 0x1FBD6: line(.upperRight, .lower)
        case 0x1FBD7: line(.upper, .lowerLeft)
        case 0x1FBD8:
            line(.upperLeft, .center)
            line(.center, .upperRight)
        case 0x1FBD9:
            line(.upperRight, .center)
            line(.center, .lowerRight)
        case 0x1FBDA:
            line(.lowerLeft, .center)
            line(.center, .lowerRight)
        case 0x1FBDB:
            line(.upperLeft, .center)
            line(.center, .lowerLeft)
        case 0x1FBDC:
            line(.upperLeft, .lower)
            line(.lower, .upperRight)
        case 0x1FBDD:
            line(.upperRight, .left)
            line(.left, .lowerRight)
        case 0x1FBDE:
            line(.lowerLeft, .upper)
            line(.upper, .lowerRight)
        case 0x1FBDF:
            line(.upperLeft, .right)
            line(.right, .lowerLeft)
        default: break
        }
    }

    private static func cellDiagonal(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ from: SpriteAlignment,
        _ to: SpriteAlignment
    ) {
        let w = Double(m.cellWidth)
        let h = Double(m.cellHeight)
        func x(_ a: SpriteAlignment) -> Double {
            switch a.horizontal {
            case .left: return 0
            case .right: return w
            case .center: return w / 2
            }
        }
        func y(_ a: SpriteAlignment) -> Double {
            switch a.vertical {
            case .top: return 0
            case .bottom: return h
            case .middle: return h / 2
            }
        }
        canvas.line(
            from: SpritePoint(x(from), y(from)), to: SpritePoint(x(to), y(to)),
            thickness: Double(SpriteThickness.light.height(m.boxThickness)), .on)
    }

    // MARK: - Circles and quarter blocks

    private static func circlesAndQuarters(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics
    ) {
        switch cp {
        case 0x1FBE0: circle(m, canvas, .upper, filled: false)
        case 0x1FBE1: circle(m, canvas, .right, filled: false)
        case 0x1FBE2: circle(m, canvas, .lower, filled: false)
        case 0x1FBE3: circle(m, canvas, .left, filled: false)
        case 0x1FBE4: SpriteBlock.block(m, canvas, .upper, 0.5, 0.5)
        case 0x1FBE5: SpriteBlock.block(m, canvas, .lower, 0.5, 0.5)
        case 0x1FBE6: SpriteBlock.block(m, canvas, .left, 0.5, 0.5)
        case 0x1FBE7: SpriteBlock.block(m, canvas, .right, 0.5, 0.5)
        case 0x1FBE8: circle(m, canvas, .upper, filled: true)
        case 0x1FBE9: circle(m, canvas, .right, filled: true)
        case 0x1FBEA: circle(m, canvas, .lower, filled: true)
        case 0x1FBEB: circle(m, canvas, .left, filled: true)
        case 0x1FBEC: circle(m, canvas, .upperRight, filled: true)
        case 0x1FBED: circle(m, canvas, .lowerLeft, filled: true)
        case 0x1FBEE: circle(m, canvas, .lowerRight, filled: true)
        case 0x1FBEF: circle(m, canvas, .upperLeft, filled: true)
        default: break
        }
    }

    /// A circle centred on a point of the cell — usually an edge or corner,
    /// so most of it falls outside and gets clipped away.
    ///
    /// Not private: the supplement block's half-circles are built from these.
    static func circle(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ position: SpriteAlignment,
        filled: Bool
    ) {
        canvas.clipToCell()

        let w = Double(m.cellWidth)
        let h = Double(m.cellHeight)
        let x: Double
        switch position.horizontal {
        case .left: x = 0
        case .right: x = w
        case .center: x = w / 2
        }
        let y: Double
        switch position.vertical {
        case .top: y = 0
        case .bottom: y = h
        case .middle: y = h / 2
        }
        let r = 0.5 * min(w, h)
        let lineWidth = Double(SpriteThickness.light.height(m.boxThickness))

        if filled {
            canvas.fillPath(.on) { ctx in
                ctx.addArc(
                    center: CGPoint(x: x, y: y), radius: CGFloat(r), startAngle: 0,
                    endAngle: 2 * .pi, clockwise: false)
                ctx.closePath()
            }
        } else {
            canvas.strokePath(.on, lineWidth: lineWidth) { ctx in
                ctx.addArc(
                    center: CGPoint(x: x, y: y), radius: CGFloat(r - lineWidth / 2),
                    startAngle: 0, endAngle: 2 * .pi, clockwise: false)
                ctx.closePath()
            }
        }
    }
}
