//  OpenTypeTable.swift
//  Just enough OpenType parsing to get the metrics CoreText rounds off.
//
//  Mirrors the subset of libghostty's `src/font/opentype/` that its CoreText
//  face reads. We go to the tables rather than asking CoreText because
//  CoreText hands back values already rounded to points and hides whether the
//  font actually specified them — and the difference between "the font says
//  the underline is here" and "CoreText guessed" is exactly what decides
//  whether underlines line up across a row of mixed fonts.
//
//  Every reader is bounds checked and returns nil on anything malformed.
//  Font files are attacker-controlled input in the general case.

import CoreText
import Foundation

enum OpenTypeTable {
    /// Raw bytes of a table, or nil if the font has no such table.
    static func copy(_ font: CTFont, _ tag: String) -> Data? {
        let scalars = Array(tag.unicodeScalars)
        guard scalars.count == 4 else { return nil }
        let value =
            (UInt32(scalars[0].value) << 24) | (UInt32(scalars[1].value) << 16)
            | (UInt32(scalars[2].value) << 8) | UInt32(scalars[3].value)
        guard let data = CTFontCopyTable(font, CTFontTableTag(value), []) else { return nil }
        return data as Data
    }

    // MARK: - Big-endian readers

    private static func u16(_ d: Data, _ off: Int) -> UInt16? {
        guard off >= 0, off + 2 <= d.count else { return nil }
        return (UInt16(d[d.startIndex + off]) << 8) | UInt16(d[d.startIndex + off + 1])
    }

    private static func i16(_ d: Data, _ off: Int) -> Int16? {
        guard let v = u16(d, off) else { return nil }
        return Int16(bitPattern: v)
    }

    private static func u32(_ d: Data, _ off: Int) -> UInt32? {
        guard let hi = u16(d, off), let lo = u16(d, off + 2) else { return nil }
        return (UInt32(hi) << 16) | UInt32(lo)
    }

    // MARK: - head

    struct Head {
        var unitsPerEm: UInt16
    }

    /// macOS bitmap-only fonts use 'bhed', which is byte-identical to 'head'.
    /// https://fontforge.org/docs/techref/bitmaponlysfnt.html
    static func head(_ font: CTFont) -> Head? {
        guard let d = copy(font, "head") ?? copy(font, "bhed") else { return nil }
        guard let upem = u16(d, 18), upem > 0 else { return nil }
        return Head(unitsPerEm: upem)
    }

    // MARK: - post

    struct Post {
        var underlinePosition: Int16
        var underlineThickness: Int16
    }

    static func post(_ font: CTFont) -> Post? {
        guard let d = copy(font, "post") else { return nil }
        guard let pos = i16(d, 8), let thick = i16(d, 10) else { return nil }
        return Post(underlinePosition: pos, underlineThickness: thick)
    }

    // MARK: - hhea

    struct Hhea {
        var ascender: Int16
        var descender: Int16
        var lineGap: Int16
    }

    static func hhea(_ font: CTFont) -> Hhea? {
        guard let d = copy(font, "hhea") else { return nil }
        guard let a = i16(d, 4), let desc = i16(d, 6), let gap = i16(d, 8) else { return nil }
        return Hhea(ascender: a, descender: desc, lineGap: gap)
    }

    // MARK: - OS/2

    struct OS2 {
        var version: UInt16
        var yStrikeoutSize: Int16
        var yStrikeoutPosition: Int16
        var useTypoMetrics: Bool
        var sTypoAscender: Int16
        var sTypoDescender: Int16
        var sTypoLineGap: Int16
        var usWinAscent: UInt16
        var usWinDescent: UInt16
        /// Version 2 and later only.
        var sxHeight: Int16?
        var sCapHeight: Int16?
    }

    static func os2(_ font: CTFont) -> OS2? {
        guard let d = copy(font, "OS/2") else { return nil }
        guard
            let version = u16(d, 0),
            let strikeSize = i16(d, 26),
            let strikePos = i16(d, 28),
            let fsSelection = u16(d, 62),
            let typoAscender = i16(d, 68),
            let typoDescender = i16(d, 70),
            let typoLineGap = i16(d, 72),
            let winAscent = u16(d, 74),
            let winDescent = u16(d, 76)
        else { return nil }

        // sxHeight and sCapHeight only exist from version 2.
        var sxHeight: Int16? = nil
        var sCapHeight: Int16? = nil
        if version >= 2 {
            sxHeight = i16(d, 86)
            sCapHeight = i16(d, 88)
        }

        return OS2(
            version: version,
            yStrikeoutSize: strikeSize,
            yStrikeoutPosition: strikePos,
            // fsSelection bit 7 is USE_TYPO_METRICS.
            useTypoMetrics: (fsSelection & 0x0080) != 0,
            sTypoAscender: typoAscender,
            sTypoDescender: typoDescender,
            sTypoLineGap: typoLineGap,
            usWinAscent: winAscent,
            usWinDescent: winDescent,
            sxHeight: sxHeight,
            sCapHeight: sCapHeight)
    }

    // MARK: - SVG

    /// Glyph ID ranges that have SVG documents, i.e. are colour glyphs.
    ///
    /// Layout: version (u16), offset to the document list (u32); at that
    /// offset a count (u16) followed by 12-byte records of
    /// (startGlyphID, endGlyphID, docOffset, docLength).
    static func svgGlyphRanges(_ font: CTFont) -> [(UInt16, UInt16)] {
        guard let d = copy(font, "SVG ") else { return [] }
        guard let version = u16(d, 0), version == 0 else { return [] }
        guard let listOffset = u32(d, 2), listOffset > 0 else { return [] }
        let base = Int(listOffset)
        guard let count = u16(d, base) else { return [] }

        var ranges: [(UInt16, UInt16)] = []
        ranges.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let off = base + 2 + i * 12
            guard let start = u16(d, off), let end = u16(d, off + 2) else { break }
            ranges.append((start, end))
        }
        return ranges
    }
}
