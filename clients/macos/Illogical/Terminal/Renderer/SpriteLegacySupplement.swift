//  SpriteLegacySupplement.swift
//  Symbols for Legacy Computing Supplement | U+1CC00...U+1CEAF
//
//  𜰡𜰢𜰣𜰤𜰥𜰦𜰧𜰨 𜰰𜰱𜰲𜰳𜰴𜰵𜰶𜰷 𜴀𜴁𜴂𜴃𜴄𜴅𜴆𜴇 𜺐𜺑𜺒𜺓𜺔𜺕𜺖𜺗
//
//  Ported from libghostty's
//  `src/font/sprite/draw/symbols_for_legacy_computing_supplement.zig`.
//
//  Introduced in Unicode 16.0. The octants are the interesting part: a 2x4
//  grid of sub-cells gives eight times the resolution of a plain cell, which
//  is what modern terminal image viewers reach for. Like the sextants, they
//  are only useful if they are exact.

import CoreGraphics
import Foundation

enum SpriteLegacySupplement {
    private static let octantMin: UInt32 = 0x1CD00
    private static let octantMax: UInt32 = 0x1CDE5

    static func has(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x1CC1B...0x1CC1E: return true  // box drawing with stubs
        case 0x1CC21...0x1CC2F: return true  // separated quadrants
        case 0x1CC30...0x1CC3F: return true  // twelfth and quarter circles
        case octantMin...octantMax: return true  // octants
        case 0x1CE00, 0x1CE01, 0x1CE0B, 0x1CE0C: return true
        case 0x1CE16...0x1CE19: return true
        case 0x1CE51...0x1CE8F: return true  // separated sextants
        case 0x1CE90...0x1CEAF: return true  // sixteenth blocks
        default: return false
        }
    }

    static func draw(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        switch cp {
        case octantMin...octantMax: octant(cp, canvas, m)
        case 0x1CC1B...0x1CC1E: boxWithStub(cp, canvas, width, height, m)
        case 0x1CC21...0x1CC2F: separatedQuadrant(cp, canvas, width, height)
        case 0x1CC30...0x1CC3F: circlePieces(cp, canvas, width, height, m)
        case 0x1CE00:
            SpriteLegacy.circle(m, canvas, .left, filled: false)
            SpriteLegacy.circle(m, canvas, .right, filled: false)
        case 0x1CE01:
            SpriteLegacy.circle(m, canvas, .upper, filled: false)
            SpriteLegacy.circle(m, canvas, .lower, filled: false)
        case 0x1CE0B:  // 𜸋 left half white ellipse
            circlePiece(canvas, width, height, m, 0, 0, 1, 0.5, .tl)
            circlePiece(canvas, width, height, m, 0, 0, 1, 0.5, .bl)
        case 0x1CE0C:  // 𜸌 right half white ellipse
            circlePiece(canvas, width, height, m, 1, 0, 1, 0.5, .tr)
            circlePiece(canvas, width, height, m, 1, 0, 1, 0.5, .br)
        case 0x1CE16...0x1CE19: verticalWithStub(cp, canvas, width, height, m)
        case 0x1CE51...0x1CE8F: separatedSextant(cp, canvas, width, height)
        case 0x1CE90...0x1CEAF: sixteenthBlock(cp, canvas, m)
        default: break
        }
    }

    // MARK: - Octants

    /// A 2x4 grid of sub-cells, one bit each, numbered 1-8 reading across
    /// then down.
    ///
    /// Transpiled from libghostty's `octants.txt`, which lists them in
    /// codepoint order because, as its own comment says, nobody could find a
    /// mathematical pattern in the assignment.
    private static let octantTable: [UInt8] = [
        0x04, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0C, 0x0D, 0x0E, 0x10, 0x11, 0x12,  // U+1CD00
        0x13, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,  // U+1CD0C
        0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x29, 0x2A, 0x2B, 0x2C,  // U+1CD18
        0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,  // U+1CD24
        0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46,  // U+1CD30
        0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x51, 0x52, 0x53,  // U+1CD3C
        0x54, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C, 0x5D, 0x5E, 0x60, 0x61, 0x62,  // U+1CD48
        0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E,  // U+1CD54
        0x6F, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A,  // U+1CD60
        0x7B, 0x7C, 0x7D, 0x7E, 0x7F, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,  // U+1CD6C
        0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x91, 0x92, 0x93,  // U+1CD78
        0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F,  // U+1CD84
        0xA1, 0xA2, 0xA3, 0xA4, 0xA6, 0xA7, 0xA8, 0xA9, 0xAB, 0xAC, 0xAD, 0xAE,  // U+1CD90
        0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB,  // U+1CD9C
        0xBC, 0xBD, 0xBE, 0xBF, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8,  // U+1CDA8
        0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4,  // U+1CDB4
        0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xE0,  // U+1CDC0
        0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC,  // U+1CDCC
        0xED, 0xEE, 0xEF, 0xF1, 0xF2, 0xF3, 0xF4, 0xF6, 0xF7, 0xF8, 0xF9, 0xFB,  // U+1CDD8
        0xFD, 0xFE,  // U+1CDE4
    ]

    private static func octant(_ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics) {
        let bits = octantTable[Int(cp - octantMin)]
        let q = SpriteFraction.quarters
        if bits & 0x01 != 0 { SpriteDraw.fill(m, canvas, .zero, .half, q[0], q[1]) }
        if bits & 0x02 != 0 { SpriteDraw.fill(m, canvas, .half, .one, q[0], q[1]) }
        if bits & 0x04 != 0 { SpriteDraw.fill(m, canvas, .zero, .half, q[1], q[2]) }
        if bits & 0x08 != 0 { SpriteDraw.fill(m, canvas, .half, .one, q[1], q[2]) }
        if bits & 0x10 != 0 { SpriteDraw.fill(m, canvas, .zero, .half, q[2], q[3]) }
        if bits & 0x20 != 0 { SpriteDraw.fill(m, canvas, .half, .one, q[2], q[3]) }
        if bits & 0x40 != 0 { SpriteDraw.fill(m, canvas, .zero, .half, q[3], q[4]) }
        if bits & 0x80 != 0 { SpriteDraw.fill(m, canvas, .half, .one, q[3], q[4]) }
    }

    // MARK: - Sixteenth blocks

    private static func sixteenthBlock(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics
    ) {
        let q = SpriteFraction.quarters
        func f(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) {
            SpriteDraw.fill(m, canvas, q[x0], q[x1], q[y0], q[y1])
        }
        switch cp {
        // The sixteen single cells of a 4x4 grid, in reading order.
        case 0x1CE90...0x1CE9F:
            let i = Int(cp - 0x1CE90)
            f(i % 4, i % 4 + 1, i / 4, i / 4 + 1)

        // Then the partial rows and columns along each edge.
        case 0x1CEA0: f(2, 4, 3, 4)
        case 0x1CEA1: f(1, 4, 3, 4)
        case 0x1CEA2: f(0, 3, 3, 4)
        case 0x1CEA3: f(0, 2, 3, 4)
        case 0x1CEA4: f(0, 1, 2, 4)
        case 0x1CEA5: f(0, 1, 1, 4)
        case 0x1CEA6: f(0, 1, 0, 3)
        case 0x1CEA7: f(0, 1, 0, 2)
        case 0x1CEA8: f(0, 2, 0, 1)
        case 0x1CEA9: f(0, 3, 0, 1)
        case 0x1CEAA: f(1, 4, 0, 1)
        case 0x1CEAB: f(2, 4, 0, 1)
        case 0x1CEAC: f(3, 4, 0, 2)
        case 0x1CEAD: f(3, 4, 0, 3)
        case 0x1CEAE: f(3, 4, 1, 4)
        case 0x1CEAF: f(3, 4, 2, 4)
        default: break
        }
    }

    // MARK: - Separated blocks

    /// Quadrants with a gap around and between them, so they read as four
    /// distinct squares rather than a filled cell.
    private static func separatedQuadrant(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32
    ) {
        // The codepoint order matches the bit order, so the low nibble is
        // the pattern directly.
        let bits = UInt8((cp - 0x1CC20) & 0xF)

        let gap = Int(max(1, width / 12))
        // Absorb the odd pixel into the middle gap so the two blocks stay
        // the same size as each other.
        let midGapX = gap * 2 + Int(width % 2)
        let midGapY = gap * 2 + Int(height % 2)

        let w = (Int(width) - gap * 2 - midGapX) / 2
        let h = (Int(height) - gap * 2 - midGapY) / 2
        guard w > 0, h > 0 else { return }

        if bits & 0x1 != 0 { canvas.box(gap, gap, gap + w, gap + h, .on) }
        if bits & 0x2 != 0 {
            canvas.box(gap + w + midGapX, gap, gap + w + midGapX + w, gap + h, .on)
        }
        if bits & 0x4 != 0 {
            canvas.box(gap, gap + h + midGapY, gap + w, gap + h + midGapY + h, .on)
        }
        if bits & 0x8 != 0 {
            canvas.box(
                gap + w + midGapX, gap + h + midGapY, gap + w + midGapX + w,
                gap + h + midGapY + h, .on)
        }
    }

    /// The same idea in a 2x3 grid.
    private static func separatedSextant(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32
    ) {
        let bits = UInt8((cp - 0x1CE50) & 0x3F)

        let gap = Int(max(1, width / 12))
        let midGapX = gap * 2 + Int(width % 2)
        let midGapY = gap * 2 + Int(height % 3) / 2

        let w = (Int(width) - gap * 2 - midGapX) / 2
        let h = (Int(height) - gap * 2 - midGapY * 2) / 3
        // Any leftover height goes to the middle row, where it is least
        // noticeable.
        let hMid = Int(height) - gap * 2 - midGapY * 2 - h * 2
        guard w > 0, h > 0, hMid > 0 else { return }

        let x0 = gap
        let x1 = gap + w + midGapX
        let yTop = gap
        let yMid = gap + h + midGapY
        let yBot = yMid + hMid + midGapY

        if bits & 0x01 != 0 { canvas.box(x0, yTop, x0 + w, yTop + h, .on) }
        if bits & 0x02 != 0 { canvas.box(x1, yTop, x1 + w, yTop + h, .on) }
        if bits & 0x04 != 0 { canvas.box(x0, yMid, x0 + w, yMid + hMid, .on) }
        if bits & 0x08 != 0 { canvas.box(x1, yMid, x1 + w, yMid + hMid, .on) }
        if bits & 0x10 != 0 { canvas.box(x0, yBot, x0 + w, yBot + h, .on) }
        if bits & 0x20 != 0 { canvas.box(x1, yBot, x1 + w, yBot + h, .on) }
    }

    // MARK: - Box drawing with stubs

    private static func boxWithStub(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        let w = Int(width)
        let h = Int(height)
        let t = Int(m.boxThickness)
        let horizontal = SpriteBox.Lines(packed: 0x40 | 0x04)  // left and right light

        switch cp {
        case 0x1CC1B:  // 𜰛 light horizontal and upper right
            SpriteBox.linesChar(m, canvas, horizontal)
            canvas.box(w - t, 0, w, h / 2, .on)
        case 0x1CC1C:  // 𜰜 light horizontal and lower right
            SpriteBox.linesChar(m, canvas, horizontal)
            canvas.box(w - t, h / 2, w, h, .on)
        case 0x1CC1D:  // 𜰝 light top and upper left
            canvas.box(0, 0, w, t, .on)
            canvas.box(0, 0, t, h / 2, .on)
        case 0x1CC1E:  // 𜰞 light bottom and lower left
            canvas.box(0, h - t, w, h, .on)
            canvas.box(0, h / 2, t, h, .on)
        default: break
        }
    }

    private static func verticalWithStub(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        let w = Int(width)
        let h = Int(height)
        let t = Int(m.boxThickness)
        let vertical = SpriteBox.Lines(packed: 0x01 | 0x10)  // up and down light
        SpriteBox.linesChar(m, canvas, vertical)

        switch cp {
        case 0x1CE16: canvas.box(w / 2, 0, w, t, .on)  // 𜸖 vertical and top right
        case 0x1CE17: canvas.box(w / 2, h - t, w, h, .on)  // 𜸗 vertical and bottom right
        case 0x1CE18: canvas.box(0, 0, w / 2, t, .on)  // 𜸘 vertical and top left
        case 0x1CE19: canvas.box(0, h - t, w / 2, h, .on)  // 𜸙 vertical and bottom left
        default: break
        }
    }

    // MARK: - Circle pieces

    private static func circlePieces(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        // (x, y, w, h, corner) as a fraction of the cell, describing which
        // slice of a larger ellipse this cell holds.
        let spec: (Double, Double, Double, Double, SpriteCorner)
        switch cp {
        case 0x1CC30: spec = (0, 0, 2, 2, .tl)
        case 0x1CC31: spec = (1, 0, 2, 2, .tl)
        case 0x1CC32: spec = (2, 0, 2, 2, .tr)
        case 0x1CC33: spec = (3, 0, 2, 2, .tr)
        case 0x1CC34: spec = (0, 1, 2, 2, .tl)
        case 0x1CC35: spec = (0, 0, 1, 1, .tl)
        case 0x1CC36: spec = (1, 0, 1, 1, .tr)
        case 0x1CC37: spec = (3, 1, 2, 2, .tr)
        case 0x1CC38: spec = (0, 2, 2, 2, .bl)
        case 0x1CC39: spec = (0, 1, 1, 1, .bl)
        case 0x1CC3A: spec = (1, 1, 1, 1, .br)
        case 0x1CC3B: spec = (3, 2, 2, 2, .br)
        case 0x1CC3C: spec = (0, 3, 2, 2, .bl)
        case 0x1CC3D: spec = (1, 3, 2, 2, .bl)
        case 0x1CC3E: spec = (2, 3, 2, 2, .br)
        case 0x1CC3F: spec = (3, 3, 2, 2, .br)
        default: return
        }
        circlePiece(canvas, width, height, m, spec.0, spec.1, spec.2, spec.3, spec.4)
    }

    /// One cell's worth of an ellipse that spans `w` x `h` cells, offset so
    /// that this cell is at grid position (x, y) within it.
    ///
    /// These characters are designed to be tiled into a larger rounded shape,
    /// so each cell draws its slice of one big arc rather than a whole small
    /// one, and the parts outside the cell are clipped away.
    private static func circlePiece(
        _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32, _ m: GridMetrics,
        _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ corner: SpriteCorner
    ) {
        let wdth = Double(width) * w
        let hght = Double(height) * h
        let xp = Double(width) * x
        let yp = Double(height) * y

        canvas.clipToCell()

        // Coefficient for approximating a quarter arc with a cubic Bézier.
        let c = (2.0.squareRoot() - 1.0) * 4.0 / 3.0
        let cw = c * wdth
        let ch = c * hght

        let thick = Double(m.boxThickness)
        // Inset by half the stroke so the arc's outer edge touches the cell
        // edge rather than straddling it.
        let ht = thick * 0.5

        canvas.strokePath(.on, lineWidth: thick, lineCap: .butt) { ctx in
            switch corner {
            case .tl:
                ctx.move(to: CGPoint(x: wdth - xp, y: ht - yp))
                ctx.addCurve(
                    to: CGPoint(x: ht - xp, y: hght - yp),
                    control1: CGPoint(x: wdth - cw - xp, y: ht - yp),
                    control2: CGPoint(x: ht - xp, y: hght - ch - yp))
            case .tr:
                ctx.move(to: CGPoint(x: wdth - xp, y: ht - yp))
                ctx.addCurve(
                    to: CGPoint(x: wdth * 2 - ht - xp, y: hght - yp),
                    control1: CGPoint(x: wdth + cw - xp, y: ht - yp),
                    control2: CGPoint(x: wdth * 2 - ht - xp, y: hght - ch - yp))
            case .bl:
                ctx.move(to: CGPoint(x: ht - xp, y: hght - yp))
                ctx.addCurve(
                    to: CGPoint(x: wdth - xp, y: hght * 2 - ht - yp),
                    control1: CGPoint(x: ht - xp, y: hght + ch - yp),
                    control2: CGPoint(x: wdth - cw - xp, y: hght * 2 - ht - yp))
            case .br:
                ctx.move(to: CGPoint(x: wdth * 2 - ht - xp, y: hght - yp))
                ctx.addCurve(
                    to: CGPoint(x: wdth - xp, y: hght * 2 - ht - yp),
                    control1: CGPoint(x: wdth * 2 - ht - xp, y: hght + ch - yp),
                    control2: CGPoint(x: wdth + cw - xp, y: hght * 2 - ht - yp))
            }
        }
    }
}
