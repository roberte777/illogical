//  SpriteGeometric.swift
//  Geometric Shapes | U+25A0...U+25FF (the drawable subset)
//  https://en.wikipedia.org/wiki/Geometric_Shapes_(Unicode_block)
//
//  ◢ ◣ ◤ ◥ ◸ ◹ ◺ ◿
//
//  Ported from libghostty's `src/font/sprite/draw/geometric_shapes.zig`.
//
//  Only the corner triangles. As libghostty notes, most of this block is
//  ordinary typography that fonts render perfectly well; the corner triangles
//  are the ones that need to fill their cell exactly so they tile.

import CoreGraphics
import Foundation

enum SpriteGeometric {
    static func has(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x25E2...0x25E5, 0x25F8...0x25FA, 0x25FF: return true
        default: return false
        }
    }

    static func draw(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        switch cp {
        case 0x25E2: cornerTriangleShade(m, canvas, .br, .on)  // ◢
        case 0x25E3: cornerTriangleShade(m, canvas, .bl, .on)  // ◣
        case 0x25E4: cornerTriangleShade(m, canvas, .tl, .on)  // ◤
        case 0x25E5: cornerTriangleShade(m, canvas, .tr, .on)  // ◥
        case 0x25F8: cornerTriangleOutline(m, canvas, .tl)  // ◸
        case 0x25F9: cornerTriangleOutline(m, canvas, .tr)  // ◹
        case 0x25FA: cornerTriangleOutline(m, canvas, .bl)  // ◺
        case 0x25FF: cornerTriangleOutline(m, canvas, .br)  // ◿
        default: break
        }
    }

    /// The three corners of the triangle that fills `corner` of the cell.
    private static func points(
        _ m: GridMetrics, _ corner: SpriteCorner
    )
        -> (SpritePoint, SpritePoint, SpritePoint)
    {
        let w = Double(m.cellWidth)
        let h = Double(m.cellHeight)
        switch corner {
        case .tl: return (SpritePoint(0, 0), SpritePoint(0, h), SpritePoint(w, 0))
        case .tr: return (SpritePoint(0, 0), SpritePoint(w, h), SpritePoint(w, 0))
        case .bl: return (SpritePoint(0, 0), SpritePoint(0, h), SpritePoint(w, h))
        case .br: return (SpritePoint(0, h), SpritePoint(w, h), SpritePoint(w, 0))
        }
    }

    static func cornerTriangleShade(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ corner: SpriteCorner,
        _ shade: SpriteShade
    ) {
        let (p0, p1, p2) = points(m, corner)
        canvas.fillTriangle(p0, p1, p2, shade.color)
    }

    static func cornerTriangleOutline(
        _ m: GridMetrics, _ canvas: SpriteCanvas, _ corner: SpriteCorner
    ) {
        let (p0, p1, p2) = points(m, corner)
        let thick = Double(SpriteThickness.light.height(m.boxThickness))
        canvas.innerStrokePath(.on, lineWidth: thick) { path in
            path.move(to: CGPoint(x: p0.x, y: p0.y))
            path.addLine(to: CGPoint(x: p1.x, y: p1.y))
            path.addLine(to: CGPoint(x: p2.x, y: p2.y))
        }
    }
}
