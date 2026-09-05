//  CellRules.swift
//  Per-codepoint rendering policy.
//
//  Ported from libghostty's `src/renderer/cell.zig`. Small predicates, but
//  each one exists because of a specific visual bug:
//
//  - `isCovering`: a full block glyph should paint the padding around the
//    grid the same colour it paints its own cell, or the edge of a filled
//    region shows a seam against the window edge.
//  - `isSymbol` + `constraintWidth`: symbol glyphs are frequently drawn
//    two cells wide by their designer. Letting them keep that width when
//    there is room, and squeezing them when there isn't, is what makes
//    icon-heavy prompts look right.
//  - `noMinContrast`: forcing contrast on box drawing would recolour half a
//    table border and break the join with the cell next to it.

import Foundation

enum CellRules {
    /// Does this glyph cover its whole cell? See libghostty #2099.
    static func isCovering(_ cp: UInt32) -> Bool {
        cp == 0x2588  // FULL BLOCK
    }

    /// Is this "symbol-like"?
    ///
    /// The definition matches the `is_symbol` table libghostty generates from
    /// the UCD: any private-use codepoint, plus a handful of symbol blocks.
    static func isSymbol(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x2190...0x21FF: return true  // Arrows
        case 0x2460...0x24FF: return true  // Enclosed Alphanumerics
        case 0x2600...0x26FF: return true  // Miscellaneous Symbols
        case 0x2700...0x27BF: return true  // Dingbats
        case 0xE000...0xF8FF: return true  // Private Use Area
        case 0x1F100...0x1F1FF: return true  // Enclosed Alphanumeric Supplement
        case 0x1F300...0x1F5FF: return true  // Misc Symbols and Pictographs
        case 0x1F600...0x1F64F: return true  // Emoticons
        case 0x1F680...0x1F6FF: return true  // Transport and Map Symbols
        case 0xF0000...0xFFFFD: return true  // Supplementary PUA-A
        case 0x100000...0x10FFFD: return true  // Supplementary PUA-B
        default: return false
        }
    }

    /// Skip the minimum-contrast correction? True for graphics elements,
    /// where a recoloured glyph would break the seam with its neighbour.
    static func noMinContrast(_ cp: UInt32) -> Bool {
        isGraphicsElement(cp)
    }

    /// Terminal graphics: box drawing, blocks, legacy computing, powerline.
    static func isGraphicsElement(_ cp: UInt32) -> Bool {
        isBoxDrawing(cp) || isBlockElement(cp) || isLegacyComputing(cp) || isPowerline(cp)
    }

    static func isBoxDrawing(_ cp: UInt32) -> Bool { (0x2500...0x257F).contains(cp) }
    static func isBlockElement(_ cp: UInt32) -> Bool { (0x2580...0x259F).contains(cp) }

    static func isLegacyComputing(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x1FB00...0x1FBFF: return true
        // Supplement, introduced in Unicode 16.0.
        case 0x1CC00...0x1CEBF: return true
        default: return false
        }
    }

    static func isPowerline(_ cp: UInt32) -> Bool { (0xE0B0...0xE0D7).contains(cp) }

    /// Spaces that a glyph is allowed to expand into. Some general spaces
    /// are deliberately excluded so that fonts still render them at a fixed
    /// width — a no-break space really should hold its cell.
    static func isSpace(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x0020, 0x2002: return true  // SPACE, EN SPACE
        default: return false
        }
    }

    /// How many cells this glyph may be scaled into.
    ///
    /// `codepointAt` returns the codepoint at a column, and `gridWidthAt`
    /// its grid width, so the caller can supply them from whatever cell
    /// representation it has.
    static func constraintWidth(
        x: Int,
        cols: Int,
        gridWidth: UInt8,
        codepoint: UInt32,
        previousCodepoint: UInt32?,
        nextCodepoint: UInt32?
    ) -> UInt8 {
        // A wide cell is always two, so answer immediately.
        if gridWidth > 1 { return gridWidth }

        // Only symbols get to expand.
        if !isSymbol(codepoint) { return gridWidth }

        // Nothing to expand into at the end of the row.
        if x == cols - 1 { return 1 }

        // If the previous glyph was also a symbol, constrain both so a run
        // of icons stays aligned. Graphics elements are exempt — they are
        // meant to butt against each other.
        if let prev = previousCodepoint, x > 0 {
            if isSymbol(prev) && !isGraphicsElement(prev) { return 1 }
        }

        // Whitespace to the right means there is room for two cells.
        let next = nextCodepoint ?? 0
        if next == 0 || isSpace(next) { return 2 }

        return 1
    }
}
