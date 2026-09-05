//  SpriteFace.swift
//  The synthetic font: glyphs we draw rather than load.
//
//  Ported from libghostty's `src/font/sprite/Face.zig`.
//
//  Two kinds of glyph live here. The special sprites — cursors, underlines,
//  strikethroughs, overlines — have no codepoint at all and are addressed by
//  a private index; no font could provide them because they have to span the
//  cell exactly. The rest are real codepoints (box drawing, blocks, braille,
//  powerline, corner triangles) that we draw ourselves because a font glyph
//  positioned by advance-width rounding does not tile.
//
//  Codepoints we don't draw fall through to the real font, which is the right
//  answer: a user with a Nerd Font installed should get its glyphs.

import Foundation

/// Sprites with no Unicode codepoint.
///
/// Unicode tops out at U+10FFFF, so these start one above it and share a
/// glyph index space with real codepoints without any chance of collision.
/// They exist only for rendering and are never written anywhere.
enum Sprite: UInt32 {
    static let start: UInt32 = 0x11_0000

    case underline = 0x11_0000
    case underlineDouble
    case underlineDotted
    case underlineDashed
    case underlineCurly
    case strikethrough
    case overline
    case cursorRect
    case cursorHollowRect
    case cursorBar
    case cursorUnderline
}

final class SpriteFace {
    private(set) var metrics: GridMetrics

    init(metrics: GridMetrics) {
        self.metrics = metrics
    }

    func updateMetrics(_ metrics: GridMetrics) {
        self.metrics = metrics
    }

    /// Whether we draw this codepoint ourselves.
    ///
    /// Presentation is ignored: whatever is asked for, our answer is the
    /// same glyph.
    static func hasCodepoint(_ cp: UInt32) -> Bool {
        if cp >= Sprite.start {
            return Sprite(rawValue: cp) != nil
        }
        switch cp {
        case SpriteBox.range: return true
        case SpriteBlock.range: return true
        case SpriteBraille.range: return true
        default: break
        }
        if SpriteGeometric.has(cp) { return true }
        if SpritePowerline.has(cp) { return true }
        if SpriteLegacy.has(cp) { return true }
        if SpriteLegacySupplement.has(cp) { return true }
        if SpriteBranch.range.contains(cp) { return true }
        return false
    }

    /// Rasterize a sprite glyph into the atlas.
    func render(
        codepoint cp: UInt32,
        into atlas: Atlas,
        options: GlyphRenderOptions
    ) throws -> Glyph {
        guard Self.hasCodepoint(cp) else { return Glyph() }

        // Wide characters get a proportionally wider sprite, so that a
        // double-width box character still reaches both edges.
        let width: UInt32
        switch options.cellWidth ?? 1 {
        case 0, 1: width = metrics.cellWidth
        case let w: width = metrics.cellWidth * UInt32(w)
        }

        // Sprites get the full cell height, except the full-height cursors,
        // which follow the (configurable) cursor height instead.
        let height: UInt32
        switch cp {
        case Sprite.cursorRect.rawValue,
            Sprite.cursorHollowRect.rawValue,
            Sprite.cursorBar.rawValue:
            height = metrics.cursorHeight
        default:
            height = metrics.cellHeight
        }

        // A quarter cell of slack on every side. Undercurls dip below the
        // cell and box joins reach past it; without the padding they would
        // be clipped rather than merely overhanging.
        let paddingX = Int(width / 4)
        let paddingY = Int(height / 4)

        let canvas = SpriteCanvas(
            cellWidth: Int(width), cellHeight: Int(height),
            paddingX: paddingX, paddingY: paddingY)

        draw(cp, canvas, width, height)

        let region = try canvas.writeAtlas(to: atlas)

        // The X offset is how far right of the cell's left edge the drawn
        // pixels start: the trimmed margin, less the padding, which sits to
        // the left of the cell.
        let offsetX = Int32(canvas.clipLeft) - Int32(paddingX)

        // Same idea vertically, plus a correction that re-centres glyphs
        // drawn at a height other than the cell height. Today only the
        // cursors do that.
        let offsetY =
            Int32(Int(region.height) + canvas.clipBottom) - Int32(paddingY)
            + (Int32(metrics.cellHeight) - Int32(height)) / 2

        return Glyph(
            width: region.width,
            height: region.height,
            offsetX: offsetX,
            offsetY: offsetY,
            atlasX: region.x,
            atlasY: region.y)
    }

    private func draw(_ cp: UInt32, _ canvas: SpriteCanvas, _ w: UInt32, _ h: UInt32) {
        if cp >= Sprite.start {
            guard let sprite = Sprite(rawValue: cp) else { return }
            switch sprite {
            case .underline: SpriteSpecial.underline(canvas, w, h, metrics)
            case .underlineDouble: SpriteSpecial.underlineDouble(canvas, w, h, metrics)
            case .underlineDotted: SpriteSpecial.underlineDotted(canvas, w, h, metrics)
            case .underlineDashed: SpriteSpecial.underlineDashed(canvas, w, h, metrics)
            case .underlineCurly: SpriteSpecial.underlineCurly(canvas, w, h, metrics)
            case .strikethrough: SpriteSpecial.strikethrough(canvas, w, h, metrics)
            case .overline: SpriteSpecial.overline(canvas, w, h, metrics)
            case .cursorRect: SpriteSpecial.cursorRect(canvas, w, h, metrics)
            case .cursorHollowRect: SpriteSpecial.cursorHollowRect(canvas, w, h, metrics)
            case .cursorBar: SpriteSpecial.cursorBar(canvas, w, h, metrics)
            case .cursorUnderline: SpriteSpecial.cursorUnderline(canvas, w, h, metrics)
            }
            return
        }

        switch cp {
        case SpriteBox.range: SpriteBox.draw(cp, canvas, w, h, metrics)
        case SpriteBlock.range: SpriteBlock.draw(cp, canvas, w, h, metrics)
        case SpriteBraille.range: SpriteBraille.draw(cp, canvas, w, h, metrics)
        default:
            if SpriteGeometric.has(cp) {
                SpriteGeometric.draw(cp, canvas, w, h, metrics)
            } else if SpritePowerline.has(cp) {
                SpritePowerline.draw(cp, canvas, w, h, metrics)
            } else if SpriteLegacy.has(cp) {
                SpriteLegacy.draw(cp, canvas, w, h, metrics)
            } else if SpriteLegacySupplement.has(cp) {
                SpriteLegacySupplement.draw(cp, canvas, w, h, metrics)
            } else if SpriteBranch.range.contains(cp) {
                SpriteBranch.draw(cp, canvas, w, h, metrics)
            }
        }
    }
}
