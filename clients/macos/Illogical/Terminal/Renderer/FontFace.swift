//  FontFace.swift
//  One CoreText font, measured and rasterized into an atlas.
//
//  Ported from libghostty's `src/font/face/coretext.zig`. Two jobs:
//
//  - `faceMetrics()` reads the OpenType tables directly rather than trusting
//    CoreText's rounded answers, because underline position in particular is
//    routinely wrong or absent and the fallbacks matter.
//  - `render(glyph:)` rasterizes one glyph at a precise sub-pixel position
//    into an atlas region. The sub-pixel handling is the fiddly part: we keep
//    the fractional part of the bearing out of the atlas coordinates and
//    fold it into the drawing transform instead, so a glyph that wants to sit
//    at x=3.4 is rasterized *as* x=3.4 rather than snapped to 3.

import CoreGraphics
import CoreText
import Foundation

/// A rasterized glyph: where it landed in the atlas and where to put it
/// relative to its cell.
struct Glyph {
    var width: UInt32 = 0
    var height: UInt32 = 0
    /// Distance from the left of the cell to the left of the glyph box.
    var offsetX: Int32 = 0
    /// Distance from the bottom of the cell to the top of the glyph box.
    var offsetY: Int32 = 0
    var atlasX: UInt32 = 0
    var atlasY: UInt32 = 0

    var isEmpty: Bool { width == 0 || height == 0 }
}

/// Which constraint applies to a glyph.
///
/// The options struct is the glyph cache's key and is hashed once per glyph
/// per frame, so it holds this rather than a `GlyphConstraint` directly: the
/// constraint is nine doubles and four enums, and hashing that ten thousand
/// times a frame is real time. Naming the constraint instead of carrying it
/// keeps the key small, and keeps the mapping from name to value in exactly
/// one place so the two can't disagree.
enum GlyphConstraintKind: Hashable {
    /// Leave the glyph alone. Every Latin character.
    case none
    /// Shrink a symbol to fit its cell(s).
    case fit
    /// Scale an emoji to cover its cells, centred.
    case emoji
    /// The per-icon rule nerd-fonts' patcher would have applied.
    case nerdFont(UInt32)

    var constraint: GlyphConstraint {
        switch self {
        case .none:
            return .none
        case .fit:
            return GlyphConstraint(size: .fit)
        case .emoji:
            // Emoji are square and much taller than a text glyph, so they
            // always get the same treatment: cover the cells they occupy,
            // centred, with a hair of padding so they don't touch.
            return GlyphConstraint(
                size: .cover, alignVertical: .center, alignHorizontal: .center,
                padLeft: 0.025, padRight: 0.025)
        case .nerdFont(let cp):
            return NerdFontConstraints.constraint(for: cp) ?? .none
        }
    }
}

/// Options controlling one rasterization.
struct GlyphRenderOptions: Hashable {
    /// How many cells the glyph occupies (its grid width).
    var cellWidth: UInt8? = nil
    var constraintKind: GlyphConstraintKind = .none
    /// Cells available horizontally for a constrained glyph. Usually 1, but
    /// 2 when there is whitespace to the right.
    var constraintWidth: UInt8 = 1
    /// Draw with font smoothing, which fattens the stroke.
    var thicken: Bool = false
    /// 0...255. 0 is the lightest thickening available, not "none".
    var thickenStrength: UInt8 = 255

    var constraint: GlyphConstraint { constraintKind.constraint }
}

enum FontFaceError: Error {
    case atlasFormatMismatch
    case bitmapContextFailed
}

/// A single font at a single size. Immutable after init and safe to read
/// from several threads: CoreText guarantees CTFont itself is thread safe.
/// The *atlas* is not, so callers serialize `render`.
final class FontFace {
    let font: CTFont
    /// Stroke width for faux-bold, when the family has no real bold.
    let syntheticBold: Double?

    /// Non-nil when the face has colour glyph tables at all.
    private let colorState: ColorState?

    /// Approximation of a 15 degree slant, for faux italics.
    static let italicSkew = CGAffineTransform(
        a: 1, b: 0, c: 0.267949, d: 1, tx: 0, ty: 0)

    init(font: CTFont, syntheticBold: Double? = nil) {
        self.font = font
        self.syntheticBold = syntheticBold
        let traits = CTFontGetSymbolicTraits(font)
        self.colorState =
            traits.contains(.traitColorGlyphs) ? ColorState(font: font) : nil
    }

    /// A copy of this face at the same size, slanted.
    func syntheticItalic() -> FontFace {
        var skew = Self.italicSkew
        let slanted = CTFontCreateCopyWithAttributes(font, 0, &skew, nil)
        return FontFace(font: slanted, syntheticBold: syntheticBold)
    }

    /// A copy of this face at the same size, drawn with a stroke to fake
    /// bold. The line width scales with point size; 1px looks right at 14pt,
    /// which is the heuristic libghostty settled on.
    func syntheticBoldCopy() -> FontFace {
        let copy = CTFontCreateCopyWithAttributes(font, 0, nil, nil)
        let points = CTFontGetSize(font)
        return FontFace(font: copy, syntheticBold: max(Double(points) / 14.0, 1))
    }

    /// A copy of this face with one OpenType variation axis pinned.
    ///
    /// Ported from libghostty's `face/coretext.zig` `setVariations`, and
    /// used for one thing: `wght = 700` is how a variable family's bold is
    /// reached. Bold is a point on an axis there, not a separate file, and
    /// `CTFontCreateCopyWithSymbolicTraits` is not a dependable way to get
    /// to it — it happens to resolve `wght`, and does nothing whatsoever for
    /// italic, which JetBrains Mono keeps in a file of its own.
    func withVariation(axis: UInt32, value: Double) -> FontFace {
        let descriptor = CTFontDescriptorCreateCopyWithVariation(
            CTFontCopyFontDescriptor(font), NSNumber(value: axis) as CFNumber, CGFloat(value))
        // Size 0 keeps the size this face already has.
        let varied = CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
        // `syntheticBold` deliberately does not carry over: a pinned weight
        // axis *is* a real weight, and keeping the stroke would draw a bold
        // on top of a bold.
        return FontFace(font: varied)
    }

    var hasColor: Bool { colorState != nil }

    func isColorGlyph(_ glyphID: UInt32) -> Bool {
        colorState?.isColorGlyph(glyphID) ?? false
    }

    /// The glyph for a codepoint, or nil if this face has none.
    func glyphIndex(_ cp: UInt32) -> UInt32? {
        guard let scalar = Unicode.Scalar(cp) else { return nil }
        var unichars = Array(String(scalar).utf16)
        if unichars.isEmpty || unichars.count > 2 { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        guard CTFontGetGlyphsForCharacters(font, &unichars, &glyphs, unichars.count) else {
            return nil
        }
        // A surrogate pair must still decode to exactly one glyph.
        if unichars.count == 2 && glyphs[1] != 0 { return nil }
        return UInt32(glyphs[0])
    }

    func hasCodepoint(_ cp: UInt32) -> Bool {
        guard let idx = glyphIndex(cp) else { return false }
        return idx != 0
    }

    // MARK: - Rasterization

    /// Rasterize `glyphIndex` into `atlas`.
    ///
    /// This is a near-line-for-line port of libghostty's CoreText renderer.
    /// The ordering of the transforms is what makes sub-pixel positioning and
    /// constraint scaling compose correctly; changing it will move glyphs.
    func render(
        glyphIndex: UInt32,
        into atlas: Atlas,
        metrics: GridMetrics,
        options: GlyphRenderOptions
    ) throws -> Glyph {
        var glyphs = [CGGlyph(truncatingIfNeeded: glyphIndex)]

        // Bounding box in a bottom-left origin, +Y up space.
        var rect = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, 1)

        let isColor = isColorGlyph(glyphIndex)
        // sbix glyphs are bitmaps, so neither synthetic bold nor smoothing
        // affects them and neither should grow the canvas.
        let sbix = isColor && (colorState?.sbix ?? false)

        // Synthetic bold strokes the outline, gaining half a line width on
        // every edge.
        if !sbix, let lineWidth = syntheticBold {
            rect.size.width += lineWidth
            rect.size.height += lineWidth
            rect.origin.x -= lineWidth / 2
            rect.origin.y -= lineWidth / 2
        }

        // Nothing to draw: no outline, or one too small to resolve.
        if rect.size.width < 0.25 || rect.size.height < 0.25 {
            return Glyph()
        }

        let cellWidth = Double(metrics.cellWidth)
        let cellHeight = Double(metrics.cellHeight)
        let cellBaseline = Double(metrics.cellBaseline)

        // The constraint operates in cell-relative coordinates, so lift the
        // bounding box off the baseline before handing it over.
        let constraint = options.constraint
        let constrained = constraint.constrain(
            GlyphSize(
                width: Double(rect.size.width),
                height: Double(rect.size.height),
                x: Double(rect.origin.x),
                y: Double(rect.origin.y) + cellBaseline),
            metrics: metrics,
            constraintWidth: options.constraintWidth)

        var x = constrained.x
        var y = constrained.y
        var width = constrained.width
        var height = constrained.height

        // When the rounded cell is wider than the face, centre the glyph in
        // it rather than leaving it hugging the left edge. Stretched glyphs
        // already accounted for the cell width, so they are exempt.
        if constraint.size != .stretch {
            let dx = (cellWidth - metrics.faceWidth) / 2
            x += dx
            if dx < 0 {
                // A cell narrower than the advance: drop the whole-pixel part
                // and keep only the fractional nudge, so sub-pixel placement
                // stays consistent.
                x -= dx.rounded(.towardZero)
            }
        }

        // Bitmap glyphs only ever land on whole pixels, so quantize position
        // and size to match or they come out soft.
        if sbix {
            width = cellWidth - (cellWidth - width - x).rounded() - x.rounded()
            height = cellHeight - (cellHeight - height - y).rounded() - y.rounded()
            x = x.rounded()
            y = y.rounded()
        }

        // Assume smoothing adds at most one pixel per edge.
        let canvasPadding: Int = (options.thicken && !sbix) ? 1 : 0

        // Whole-pixel bearings; the fraction is applied during rasterization.
        let pxX = Int32(x.rounded(.down)) - Int32(canvasPadding)
        let pxY = Int32(y.rounded(.down)) - Int32(canvasPadding)

        let fracX = x - x.rounded(.down)
        let fracY = y - y.rounded(.down)

        // Ceil after adding the fraction so the canvas definitely contains
        // the drawn glyph, smoothing included.
        let pxWidth = UInt32((width + fracX).rounded(.up)) + UInt32(2 * canvasPadding)
        let pxHeight = UInt32((height + fracY).rounded(.up)) + UInt32(2 * canvasPadding)
        guard pxWidth > 0, pxHeight > 0 else { return Glyph() }

        let depth = isColor ? 4 : 1
        guard atlas.format.depth == depth else { throw FontFaceError.atlasFormatMismatch }

        let byteCount = Int(pxWidth) * Int(pxHeight) * depth
        let buf = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        let colorSpace: CGColorSpace
        let bitmapInfo: UInt32
        if isColor {
            colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
            bitmapInfo =
                CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.linearGray)!
            bitmapInfo = CGImageAlphaInfo.alphaOnly.rawValue
        }

        guard
            let ctx = CGContext(
                data: buf,
                width: Int(pxWidth),
                height: Int(pxHeight),
                bitsPerComponent: 8,
                bytesPerRow: Int(pxWidth) * depth,
                space: colorSpace,
                bitmapInfo: bitmapInfo)
        else { throw FontFaceError.bitmapContextFailed }

        // Explicit fill so no pixel is left uninitialized.
        if isColor {
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0)
        } else {
            ctx.setFillColor(gray: 0, alpha: 0)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: Int(pxWidth), height: Int(pxHeight)))

        // "Font smoothing" is what we call thickening: a dilation that
        // compensates for optical thinning, and which makes text look closer
        // to other Mac apps for users who want that.
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(options.thicken)

        // We place glyphs at fractional positions deliberately, so ask for
        // sub-pixel positioning and explicitly refuse quantization.
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.setShouldSubpixelQuantizeFonts(false)

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        if isColor {
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        } else {
            // In an alpha-only context the grey level is what drives the
            // smoothing dilation, which is how thicken-strength is applied.
            let strength = Double(options.thickenStrength) / 255.0
            ctx.setFillColor(gray: strength, alpha: 1)
            ctx.setStrokeColor(gray: strength, alpha: 1)
        }

        if let lineWidth = syntheticBold {
            ctx.setTextDrawingMode(.fillStroke)
            ctx.setLineWidth(lineWidth)
        }

        // Move the origin to the sub-pixel position we actually want. The
        // glyph is drawn with its box at exactly [0, 0] (see the negated
        // bearings below), so this translation *is* its position.
        ctx.translateBy(x: fracX + Double(canvasPadding), y: fracY + Double(canvasPadding))

        // Then scale so the drawn glyph comes out at the constrained size.
        ctx.scaleBy(
            x: width / Double(rect.size.width),
            y: height / Double(rect.size.height))

        // Negating the bearings puts the glyph's box corner at [0, 0], which
        // the translation above then moves into place.
        var positions = [CGPoint(x: -rect.origin.x, y: -rect.origin.y)]
        CTFontDrawGlyphs(font, &glyphs, &positions, 1, ctx)

        let region = try atlas.reserve(width: pxWidth, height: pxHeight)
        atlas.set(region, buf)

        return Glyph(
            width: pxWidth,
            height: pxHeight,
            offsetX: pxX,
            // Distance from the cell bottom to the *top* of the box.
            offsetY: pxY + Int32(pxHeight),
            atlasX: region.x,
            atlasY: region.y)
    }

    // MARK: - Metrics

    /// Measure this face. Prefers the OpenType tables over CoreText, falling
    /// back per-metric when a table is missing or degenerate.
    func faceMetrics() -> FaceMetrics {
        let head = OpenTypeTable.head(font)
        let post = OpenTypeTable.post(font)
        let os2 = OpenTypeTable.os2(font)
        let hhea = OpenTypeTable.hhea(font)

        let unitsPerEm = Double(head?.unitsPerEm ?? UInt16(CTFontGetUnitsPerEm(font)))
        let pxPerEm = Double(CTFontGetSize(font))
        let pxPerUnit = unitsPerEm > 0 ? pxPerEm / unitsPerEm : 0

        let (ascent, descent, lineGap): (Double, Double, Double) = {
            guard let hhea else {
                return (
                    Double(CTFontGetAscent(font)),
                    -Double(CTFontGetDescent(font)),
                    Double(CTFontGetLeading(font))
                )
            }

            let hheaAscent = Double(hhea.ascender) * pxPerUnit
            let hheaDescent = Double(hhea.descender) * pxPerUnit
            let hheaLineGap = Double(hhea.lineGap) * pxPerUnit

            guard let os2 else { return (hheaAscent, hheaDescent, hheaLineGap) }

            let os2Ascent = Double(os2.sTypoAscender) * pxPerUnit
            let os2Descent = Double(os2.sTypoDescender) * pxPerUnit
            let os2LineGap = Double(os2.sTypoLineGap) * pxPerUnit

            // If the font says to use typo metrics, believe it.
            if os2.useTypoMetrics { return (os2Ascent, os2Descent, os2LineGap) }

            // Otherwise prefer hhea, then OS/2 sTypo*, then OS/2 usWin*.
            // Not standard, but fonts are weird, and it is roughly what
            // FreeType does for its generic ascent and descent.
            if hhea.ascender != 0 || hhea.descender != 0 {
                return (hheaAscent, hheaDescent, hheaLineGap)
            }
            if os2.sTypoAscender != 0 || os2.sTypoDescender != 0 {
                return (os2Ascent, os2Descent, os2LineGap)
            }
            // usWinDescent is positive-down, unlike the others.
            return (
                Double(os2.usWinAscent) * pxPerUnit,
                -Double(os2.usWinDescent) * pxPerUnit,
                0
            )
        }()

        // Some fonts ship a degenerate 'post' table with a zero thickness.
        // Treat those as absent so the estimator takes over, but keep a
        // non-zero position even when the thickness is broken.
        let (underlinePosition, underlineThickness): (Double?, Double?) = {
            guard let post else { return (nil, nil) }
            let broken = post.underlineThickness == 0
            let pos: Double? =
                (broken && post.underlinePosition == 0)
                ? nil : Double(post.underlinePosition) * pxPerUnit
            let thick: Double? = broken ? nil : Double(post.underlineThickness) * pxPerUnit
            return (pos, thick)
        }()

        let (strikethroughPosition, strikethroughThickness): (Double?, Double?) = {
            guard let os2 else { return (nil, nil) }
            let broken = os2.yStrikeoutSize == 0
            let pos: Double? =
                (broken && os2.yStrikeoutPosition == 0)
                ? nil : Double(os2.yStrikeoutPosition) * pxPerUnit
            let thick: Double? = broken ? nil : Double(os2.yStrikeoutSize) * pxPerUnit
            return (pos, thick)
        }()

        let (capHeight, exHeight): (Double, Double) = {
            guard let os2 else {
                return (Double(CTFontGetCapHeight(font)), Double(CTFontGetXHeight(font)))
            }
            return (
                os2.sCapHeight.map { Double($0) * pxPerUnit } ?? Double(CTFontGetCapHeight(font)),
                os2.sxHeight.map { Double($0) * pxPerUnit } ?? Double(CTFontGetXHeight(font))
            )
        }()

        // Cell width is the widest advance over printable ASCII (usually 'M',
        // but we don't assume). ASCII height is the height of the combined
        // bounding box of the same set.
        let (cellWidth, asciiHeight): (Double, Double) = {
            var unichars = [UniChar]((32..<127).map { UniChar($0) })
            var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
            _ = CTFontGetGlyphsForCharacters(font, &unichars, &glyphs, unichars.count)

            var advances = [CGSize](repeating: .zero, count: glyphs.count)
            _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, glyphs.count)

            var maxAdvance: Double = 0
            for a in advances { maxAdvance = max(maxAdvance, Double(a.width)) }

            let rect = CTFontGetBoundingRectsForGlyphs(
                font, .horizontal, &glyphs, nil, glyphs.count)
            return (maxAdvance, Double(rect.size.height))
        }()

        // 水 (U+6C34) normalizes CJK faces mixed with Latin ones.
        let icWidth: Double? = {
            guard let idx = glyphIndex(0x6C34), idx != 0 else { return nil }
            var glyphs = [CGGlyph(truncatingIfNeeded: idx)]
            let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, nil, 1)
            let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, 1)
            // A glyph wider than its own advance means the metric is wrong —
            // typically a CJK font mangled by the Nerd Font patcher. Using it
            // would blow the font size up, so discard it.
            if Double(bounds.size.width) > advance { return nil }
            return advance
        }()

        return FaceMetrics(
            pxPerEm: pxPerEm,
            cellWidth: cellWidth,
            ascent: ascent,
            descent: descent,
            lineGap: lineGap,
            underlinePosition: underlinePosition,
            underlineThickness: underlineThickness,
            strikethroughPosition: strikethroughPosition,
            strikethroughThickness: strikethroughThickness,
            capHeight: capHeight,
            exHeight: exHeight,
            asciiHeight: asciiHeight,
            icWidth: icWidth)
    }
}

/// Which glyphs of a face are in colour.
private struct ColorState {
    /// True if the face has an sbix table at all. Like libghostty, we treat
    /// its mere presence as "every glyph is colour" — good enough for Apple
    /// Color Emoji, which is the case that matters.
    let sbix: Bool
    /// Glyph ranges covered by the SVG table, if any.
    let svgRanges: [(UInt16, UInt16)]

    init(font: CTFont) {
        sbix = (OpenTypeTable.copy(font, "sbix")?.count ?? 0) > 0
        svgRanges = OpenTypeTable.svgGlyphRanges(font)
    }

    func isColorGlyph(_ glyphID: UInt32) -> Bool {
        // Our glyph IDs are 32-bit to leave room for sprite indices; real
        // fonts only use 16 bits, so anything wider cannot be a colour glyph.
        guard glyphID <= UInt16.max else { return false }
        if sbix { return true }
        let id = UInt16(glyphID)
        for (lo, hi) in svgRanges where id >= lo && id <= hi { return true }
        return false
    }
}
