//  SpriteBranch.swift
//  Branch Drawing Characters | U+F5D0...U+F60D
//
//  Ported from libghostty's `src/font/sprite/draw/branch.zig`.
//
//  The set used to draw git-style commit graphs, originally specified for
//  Kitty (kovidgoyal/kitty#7681, #7805). Like box drawing, the point is that
//  a vertical branch line must be continuous down a column and meet its
//  arcs and nodes exactly, which font glyphs positioned by advance-width
//  rounding do not.

import CoreGraphics
import Foundation

enum SpriteBranch {
    static let range: ClosedRange<UInt32> = 0xF5D0...0xF60D

    /// A node: a circle, filled or hollow, with optional stubs reaching out
    /// to each of the four edges.
    private struct Node {
        var up = false
        var right = false
        var down = false
        var left = false
        var filled = false
    }

    static func draw(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ width: UInt32, _ height: UInt32,
        _ m: GridMetrics
    ) {
        switch cp {
        case 0xF5D0: SpriteDraw.hlineMiddle(m, canvas, .light)
        case 0xF5D1: SpriteDraw.vlineMiddle(m, canvas, .light)
        case 0xF5D2: fadingLine(m, canvas, to: .right)
        case 0xF5D3: fadingLine(m, canvas, to: .left)
        case 0xF5D4: fadingLine(m, canvas, to: .bottom)
        case 0xF5D5: fadingLine(m, canvas, to: .top)

        case 0xF5D6: SpriteBox.arc(m, canvas, .br, .light)
        case 0xF5D7: SpriteBox.arc(m, canvas, .bl, .light)
        case 0xF5D8: SpriteBox.arc(m, canvas, .tr, .light)
        case 0xF5D9: SpriteBox.arc(m, canvas, .tl, .light)

        case 0xF5DA:
            SpriteDraw.vlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .tr, .light)
        case 0xF5DB:
            SpriteDraw.vlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .br, .light)
        case 0xF5DC:
            SpriteBox.arc(m, canvas, .tr, .light)
            SpriteBox.arc(m, canvas, .br, .light)
        case 0xF5DD:
            SpriteDraw.vlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .tl, .light)
        case 0xF5DE:
            SpriteDraw.vlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .bl, .light)
        case 0xF5DF:
            SpriteBox.arc(m, canvas, .tl, .light)
            SpriteBox.arc(m, canvas, .bl, .light)

        case 0xF5E0:
            SpriteBox.arc(m, canvas, .bl, .light)
            SpriteDraw.hlineMiddle(m, canvas, .light)
        case 0xF5E1:
            SpriteBox.arc(m, canvas, .br, .light)
            SpriteDraw.hlineMiddle(m, canvas, .light)
        case 0xF5E2:
            SpriteBox.arc(m, canvas, .br, .light)
            SpriteBox.arc(m, canvas, .bl, .light)
        case 0xF5E3:
            SpriteBox.arc(m, canvas, .tl, .light)
            SpriteDraw.hlineMiddle(m, canvas, .light)
        case 0xF5E4:
            SpriteBox.arc(m, canvas, .tr, .light)
            SpriteDraw.hlineMiddle(m, canvas, .light)
        case 0xF5E5:
            SpriteBox.arc(m, canvas, .tr, .light)
            SpriteBox.arc(m, canvas, .tl, .light)

        case 0xF5E6:
            SpriteDraw.vlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .tl, .light)
            SpriteBox.arc(m, canvas, .tr, .light)
        case 0xF5E7:
            SpriteDraw.vlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .bl, .light)
            SpriteBox.arc(m, canvas, .br, .light)
        case 0xF5E8:
            SpriteDraw.hlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .bl, .light)
            SpriteBox.arc(m, canvas, .tl, .light)
        case 0xF5E9:
            SpriteDraw.hlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .tr, .light)
            SpriteBox.arc(m, canvas, .br, .light)
        case 0xF5EA:
            SpriteDraw.vlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .tl, .light)
            SpriteBox.arc(m, canvas, .br, .light)
        case 0xF5EB:
            SpriteDraw.vlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .tr, .light)
            SpriteBox.arc(m, canvas, .bl, .light)
        case 0xF5EC:
            SpriteDraw.hlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .tl, .light)
            SpriteBox.arc(m, canvas, .br, .light)
        case 0xF5ED:
            SpriteDraw.hlineMiddle(m, canvas, .light)
            SpriteBox.arc(m, canvas, .tr, .light)
            SpriteBox.arc(m, canvas, .bl, .light)

        case 0xF5EE...0xF60D: node(cp, canvas, m)

        default: break
        }
    }

    /// Which arms each node has, indexed by `(cp - 0xF5EE) / 2`.
    /// Bits: up 1, right 2, down 4, left 8.
    ///
    /// The pairs alternate filled then hollow, and the arm patterns follow no
    /// arithmetic order, so this is a table.
    private static let nodeArms: [UInt8] = [
        0,  // (none)
        2,  // right
        8,  // left
        10,  // left right
        4,  // down
        1,  // up
        5,  // up down
        6,  // right down
        12,  // left down
        3,  // up right
        9,  // up left
        7,  // up down right
        13,  // up down left
        14,  // down left right
        11,  // up left right
        15,  // all
    ]

    private static func node(_ cp: UInt32, _ canvas: SpriteCanvas, _ m: GridMetrics) {
        let offset = Int(cp - 0xF5EE)
        let arms = nodeArms[offset / 2]
        // Even codepoints are filled, odd are hollow.
        let node = Node(
            up: arms & 1 != 0,
            right: arms & 2 != 0,
            down: arms & 4 != 0,
            left: arms & 8 != 0,
            filled: offset % 2 == 0)
        drawNode(m, canvas, node)
    }

    private static func drawNode(_ m: GridMetrics, _ canvas: SpriteCanvas, _ node: Node) {
        let thickPx = SpriteThickness.light.height(m.boxThickness)
        let w = Double(m.cellWidth)
        let h = Double(m.cellHeight)
        let thick = Double(thickPx)

        let hTop = Int((m.cellHeight - min(m.cellHeight, thickPx)) / 2)
        let hBottom = hTop + Int(thickPx)
        let vLeft = Int((m.cellWidth - min(m.cellWidth, thickPx)) / 2)
        let vRight = vLeft + Int(thickPx)

        // Centre the circle on the stroke rather than on the cell, so it
        // lines up with box drawing characters — those lines are deliberately
        // off-centre when the cell size and stroke width disagree in parity.
        let cx = Double(vLeft) + thick / 2
        let cy = Double(hTop) + thick / 2
        // The radius is the shortest distance from the centre to any edge.
        let r = min(min(cx, cy), min(w - cx, h - cy))

        // Arms run from the edge of the circle out to the edge of the cell.
        if node.up {
            canvas.box(vLeft, 0, vRight, Int((cy - r + thick / 2).rounded(.up)), .on)
        }
        if node.right {
            canvas.box(
                Int((cx + r - thick / 2).rounded(.down)), hTop, Int(m.cellWidth), hBottom, .on)
        }
        if node.down {
            canvas.box(
                vLeft, Int((cy + r - thick / 2).rounded(.down)), vRight, Int(m.cellHeight),
                .on)
        }
        if node.left {
            canvas.box(0, hTop, Int((cx - r + thick / 2).rounded(.up)), hBottom, .on)
        }

        if node.filled {
            canvas.fillPath(.on) { ctx in
                ctx.addArc(
                    center: CGPoint(x: cx, y: cy), radius: CGFloat(r), startAngle: 0,
                    endAngle: 2 * .pi, clockwise: false)
                ctx.closePath()
            }
        } else {
            canvas.strokePath(.on, lineWidth: thick) { ctx in
                ctx.addArc(
                    center: CGPoint(x: cx, y: cy), radius: CGFloat(r - thick / 2),
                    startAngle: 0, endAngle: 2 * .pi, clockwise: false)
                ctx.closePath()
            }
        }
    }

    /// A line that fades to nothing toward one edge, marking where a branch
    /// leaves the visible graph.
    private static func fadingLine(
        _ m: GridMetrics, _ canvas: SpriteCanvas, to edge: SpriteEdge
    ) {
        let thickPx = SpriteThickness.light.height(m.boxThickness)
        let w = Double(m.cellWidth)
        let h = Double(m.cellHeight)

        let hTop = Int((m.cellHeight - min(m.cellHeight, thickPx)) / 2)
        let hBottom = hTop + Int(thickPx)
        let vLeft = Int((m.cellWidth - min(m.cellWidth, thickPx)) / 2)
        let vRight = vLeft + Int(thickPx)

        // Fading toward the top or left means starting transparent and
        // ramping up; toward the bottom or right, the reverse.
        var color: Double
        let increment: Double
        switch edge {
        case .top:
            color = 0
            increment = 255 / h
        case .bottom:
            color = 255
            increment = -255 / h
        case .left:
            color = 0
            increment = 255 / w
        case .right:
            color = 255
            increment = -255 / w
        }

        switch edge {
        case .top, .bottom:
            for y in 0..<Int(m.cellHeight) {
                let value = UInt8(max(0, min(255, color.rounded())))
                for x in vLeft..<vRight {
                    canvas.pixel(x, y, SpriteColor(value: value))
                }
                color += increment
            }
        case .left, .right:
            for x in 0..<Int(m.cellWidth) {
                let value = UInt8(max(0, min(255, color.rounded())))
                for y in hTop..<hBottom {
                    canvas.pixel(x, y, SpriteColor(value: value))
                }
                color += increment
            }
        }
    }
}
