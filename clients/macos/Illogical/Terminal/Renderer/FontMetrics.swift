//  FontMetrics.swift
//  Turning a font face's metadata into a pixel grid.
//
//  Ported from libghostty's `src/font/Metrics.zig`. Every number a terminal
//  renderer needs — cell size, baseline, where an underline sits — comes from
//  here, and the rounding decisions are load-bearing: the cell must be an
//  integer number of pixels, but the font's own dimensions are not, and how
//  you absorb that error is the difference between text that looks centred and
//  text that looks like it is sliding out of its row.

import Foundation

/// Metrics as the font reports them, in pixels at the current size, before
/// any rounding. Nil fields mean the font did not say and we will estimate.
struct FaceMetrics {
    /// Pixels per em. Dividing the rest of this struct by it gives ems, which
    /// is how you compare faces rendered at different sizes.
    var pxPerEm: Double

    /// The narrowest cell that still contains every printable ASCII glyph.
    var cellWidth: Double

    /// Relative to the baseline, +Y up.
    var ascent: Double
    /// Relative to the baseline, +Y up. Normally negative.
    var descent: Double
    /// Extra space between lines, on top of ascent - descent. Positive.
    var lineGap: Double

    /// Top of the underline stroke, relative to the baseline, +Y up.
    var underlinePosition: Double?
    var underlineThickness: Double?

    /// Top of the strikethrough stroke, relative to the baseline, +Y up.
    var strikethroughPosition: Double?
    var strikethroughThickness: Double?

    var capHeight: Double?
    var exHeight: Double?

    /// Height of the bounding box over all printable ASCII. Differs from
    /// ascent - descent because symbols like @ and $ overshoot, and because
    /// many fonts bake the line gap into ascent/descent.
    var asciiHeight: Double?

    /// Width of 水 (U+6C34), used to normalize CJK faces mixed with Latin ones.
    var icWidth: Double?

    var lineHeight: Double { ascent - descent + lineGap }

    func resolvedCapHeight() -> Double {
        if let v = capHeight, v > 0 { return v }
        return 0.75 * ascent
    }

    func resolvedExHeight() -> Double {
        if let v = exHeight, v > 0 { return v }
        return 0.75 * resolvedCapHeight()
    }

    /// 1.5x cap height is the estimator libghostty settled on after measuring
    /// across programming fonts.
    func resolvedAsciiHeight() -> Double {
        if let v = asciiHeight, v > 0 { return v }
        return 1.5 * resolvedCapHeight()
    }

    func resolvedIcWidth() -> Double {
        if let v = icWidth, v > 0 { return v }
        return min(resolvedAsciiHeight(), 2 * cellWidth)
    }

    func resolvedUnderlineThickness() -> Double {
        if let v = underlineThickness, v > 0 { return v }
        return 0.15 * resolvedExHeight()
    }

    func resolvedStrikethroughThickness() -> Double {
        if let v = strikethroughThickness, v > 0 { return v }
        return resolvedUnderlineThickness()
    }

    // Positions, unlike sizes, are legitimately negative, so there is no
    // sign check on these two.

    func resolvedUnderlinePosition() -> Double {
        underlinePosition ?? -resolvedUnderlineThickness()
    }

    /// Centred on half the ex height, so it strikes through lowercase text.
    func resolvedStrikethroughPosition() -> Double {
        strikethroughPosition
            ?? (resolvedExHeight() + resolvedStrikethroughThickness()) * 0.5
    }
}

/// The pixel grid derived from a face. Everything here is in device pixels
/// and already scaled for the display.
struct GridMetrics: Equatable {
    var cellWidth: UInt32
    var cellHeight: UInt32

    /// Distance from the *bottom* of the cell to the baseline. The only
    /// bottom-relative value in this struct.
    var cellBaseline: UInt32

    /// Distance from the top of the cell to the top of the stroke.
    var underlinePosition: UInt32
    var underlineThickness: UInt32

    var strikethroughPosition: UInt32
    var strikethroughThickness: UInt32

    /// May be negative to sit above the cell.
    var overlinePosition: Int32
    var overlineThickness: UInt32

    /// Stroke width for box drawing characters.
    var boxThickness: UInt32

    /// Not a font property — this is a user preference, hence the default.
    var cursorThickness: UInt32 = 1
    var cursorHeight: UInt32

    /// Constraint height for Nerd Font icons, multi-cell and single-cell.
    var iconHeight: Double
    var iconHeightSingle: Double

    /// The unrounded face dimensions, kept because the constraint maths needs
    /// to know how much error rounding introduced.
    var faceWidth: Double
    var faceHeight: Double

    /// Offset from the bottom of the cell to the bottom of the face's
    /// bounding box, after rounding.
    var faceY: Double

    /// Floors that stop a modifier or a pathological font from producing,
    /// say, a zero-thickness underline.
    private mutating func clamp() {
        cellWidth = max(1, cellWidth)
        cellHeight = max(1, cellHeight)
        underlineThickness = max(1, underlineThickness)
        strikethroughThickness = max(1, strikethroughThickness)
        overlineThickness = max(1, overlineThickness)
        boxThickness = max(1, boxThickness)
        cursorThickness = max(1, cursorThickness)
        cursorHeight = max(1, cursorHeight)
        iconHeight = max(1.0, iconHeight)
        iconHeightSingle = max(1.0, iconHeightSingle)
        faceHeight = max(1.0, faceHeight)
        faceWidth = max(1.0, faceWidth)
    }

    /// Derive the grid from a face. Pass unrounded values; this function owns
    /// every rounding decision.
    static func calc(_ face: FaceMetrics) -> GridMetrics {
        let faceWidth = face.cellWidth
        let faceHeight = face.lineHeight

        // Round rather than ceil. Rounding keeps the cell within half a pixel
        // of the font's intent, which matches authorial intent better and
        // makes apparent spacing consistent between low and high DPI. The
        // cost is that a glyph with no side bearing can overhang by a pixel,
        // but such glyphs are usually meant to connect to their neighbours
        // anyway. The same argument applies to height: forcing the cell to
        // contain every descender gives line heights nobody wants.
        let cellWidth = faceWidth.rounded()
        let cellHeight = faceHeight.rounded()

        // Half the line gap above the text and half below, so glyphs never
        // touch either edge of the cell.
        let halfLineGap = face.lineGap / 2

        // Bottom-relative, unlike everything else here.
        let faceBaseline = halfLineGap - face.descent
        // Centre the face in the rounded cell: whichever way the rounding
        // went, the face overhangs or insets equally top and bottom.
        let cellBaseline = (faceBaseline - (cellHeight - faceHeight) / 2).rounded()

        // How far the baseline we draw at has moved from the one the font
        // asked for. Nothing has been scaled yet, so this is also the offset
        // from the cell bottom to the face's bounding box bottom.
        let faceY = cellBaseline - faceBaseline

        let topToBaseline = cellHeight - cellBaseline

        let capHeight = face.resolvedCapHeight()
        let underlineThickness = max(1, face.resolvedUnderlineThickness().rounded(.up))
        let strikethroughThickness = max(
            1, face.resolvedStrikethroughThickness().rounded(.up))
        let underlinePosition = (topToBaseline - face.resolvedUnderlinePosition()).rounded()
        let strikethroughPosition =
            (topToBaseline - face.resolvedStrikethroughPosition()).rounded()

        // Same heuristic as nerd-fonts' font-patcher. Kept separate from
        // faceHeight so an icon-height adjustment doesn't move the grid.
        let iconHeight = faceHeight
        let iconHeightSingle = (2 * capHeight + faceHeight) / 3

        var result = GridMetrics(
            cellWidth: UInt32(max(0, cellWidth)),
            cellHeight: UInt32(max(0, cellHeight)),
            cellBaseline: UInt32(max(0, cellBaseline)),
            underlinePosition: UInt32(max(0, underlinePosition)),
            underlineThickness: UInt32(underlineThickness),
            strikethroughPosition: UInt32(max(0, strikethroughPosition)),
            strikethroughThickness: UInt32(strikethroughThickness),
            overlinePosition: 0,
            overlineThickness: UInt32(underlineThickness),
            boxThickness: UInt32(underlineThickness),
            cursorThickness: 1,
            cursorHeight: UInt32(max(0, cellHeight)),
            iconHeight: iconHeight,
            iconHeightSingle: iconHeightSingle,
            faceWidth: faceWidth,
            faceHeight: faceHeight,
            faceY: faceY)

        result.clamp()
        return result
    }
}

/// How a fallback face is scaled so it sits with the face beside it.
///
/// Ported from libghostty's `Collection.SizeAdjustment`. A fallback loaded at
/// the same point size as the primary is not the same *apparent* size — two
/// families at 13pt can differ by a third in how tall their letters actually
/// are — so the face is scaled until a chosen metric matches. libghostty's
/// own note is that this "functions very much like the `font-size-adjust` CSS
/// property".
enum SizeAdjustment {
    /// Leave the face at the size it was asked for.
    case none
    /// Match the width of an ideograph, which is what lines a CJK face up on
    /// the grid. libghostty's default for every fallback.
    case icWidth
    case exHeight
    case capHeight
    case lineHeight
}

extension FaceMetrics {
    /// Whether the font actually stated a metric, rather than us estimating
    /// one for it. A zero or negative value is a font saying nothing in a
    /// more annoying way, so it counts as absent.
    private static func stated(_ value: Double?) -> Bool { (value ?? 0) > 0 }

    /// What to multiply `face`'s size by so that it matches `primary` under
    /// `adjustment`.
    ///
    /// Both sides are normalized to ems before they are compared, which is
    /// what makes the answer independent of the sizes the two faces happen to
    /// be loaded at.
    ///
    /// The chain is libghostty's, and the reason for it is that the metric
    /// asked for may be one this particular font never stated: a face with no
    /// ideographs usually has no `ic_width`, and scaling by an *estimate* of
    /// one would be scaling by a number derived from the very face we are
    /// trying to correct. So each step falls through to a metric more fonts
    /// bother to carry, ending at line height, which every font has because
    /// it is computed rather than read.
    static func scaleFactor(
        primary: FaceMetrics, face: FaceMetrics, adjustment: SizeAdjustment
    ) -> Double {
        guard adjustment != .none else { return 1 }
        guard primary.pxPerEm > 0, face.pxPerEm > 0 else { return 1 }

        // Per em, so the sizes the faces were measured at drop out.
        let primaryScale = 1 / primary.pxPerEm
        let faceScale = 1 / face.pxPerEm

        var step = adjustment
        // Walk to the first metric this face actually states. `lineHeight`
        // terminates it, so this cannot spin.
        while true {
            switch step {
            case .icWidth where !stated(face.icWidth): step = .exHeight
            case .exHeight where !stated(face.exHeight): step = .capHeight
            case .capHeight where !stated(face.capHeight): step = .lineHeight
            default:
                let (p, f): (Double, Double) = {
                    switch step {
                    case .icWidth: return (primary.resolvedIcWidth(), face.resolvedIcWidth())
                    case .exHeight: return (primary.resolvedExHeight(), face.resolvedExHeight())
                    case .capHeight:
                        return (primary.resolvedCapHeight(), face.resolvedCapHeight())
                    default: return (primary.lineHeight, face.lineHeight)
                    }
                }()

                let factor = (p * primaryScale) / (f * faceScale)
                // A face that measures as zero or worse would otherwise be
                // reloaded at a size of infinity or nothing. libghostty has
                // no such guard because its metrics come from FreeType, which
                // will not hand back a degenerate face; CoreText, asked about
                // a font it half-understands, will.
                guard factor.isFinite, factor > 0 else { return 1 }
                return factor
            }
        }
    }
}
