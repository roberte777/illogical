//  GlyphConstraint.swift
//  Rules for squeezing a glyph into its cell(s).
//
//  Ported from libghostty's `src/font/Glyph.zig`. A monospace grid is a hard
//  constraint that most glyphs were never designed for: emoji are square and
//  huge, Nerd Font icons come from a patcher script with its own scaling
//  rules, box drawing has to tile seamlessly. This is the arithmetic that
//  reconciles them, and it is the same arithmetic nerd-fonts' font-patcher
//  uses, so patched and unpatched fonts land in the same place.

import Foundation

/// A glyph's size and position, in pixels, relative to the bottom-left of
/// its cell with +Y up.
struct GlyphSize: Equatable {
    var width: Double
    var height: Double
    var x: Double
    var y: Double
}

struct GlyphConstraint: Equatable, Hashable {
    enum Size: UInt8 {
        /// Leave the size alone.
        case none
        /// Shrink to fit, preserving aspect ratio.
        case fit
        /// Scale either way to match the bounds, preserving aspect ratio.
        case cover
        /// Shrink to fit; if the result doesn't fill one cell, grow to fill
        /// it; if it exceeds one cell but is within bounds, leave it.
        /// A Nerd Font rule.
        case fitCover1
        /// Fill the bounds in both axes, ignoring aspect ratio.
        case stretch
    }

    enum Align: UInt8 {
        case none
        /// Leading edge (bottom or left) to the leading edge of the axis.
        case start
        /// Trailing edge (top or right) to the trailing edge of the axis.
        case end
        case center
        /// Centre on the first cell even for multi-cell constraints.
        /// A Nerd Font rule.
        case center1
    }

    enum Height: UInt8 {
        /// Constrain against the full line height of the primary face.
        case cell
        /// Constrain against the icon height, which varies with the
        /// constraint width.
        case icon
    }

    var size: Size = .none
    var alignVertical: Align = .none
    var alignHorizontal: Align = .none

    /// Padding as a fraction of the face dimensions.
    var padTop: Double = 0
    var padLeft: Double = 0
    var padRight: Double = 0
    var padBottom: Double = 0

    /// This glyph's size and bearings relative to the bounding box of the
    /// group it scales with. Nerd Font icons are scaled as families so that,
    /// say, every battery level ends up the same size.
    var relativeWidth: Double = 1.0
    var relativeHeight: Double = 1.0
    var relativeX: Double = 0.0
    var relativeY: Double = 0.0

    /// Cap on width/height when stretching.
    var maxXYRatio: Double? = nil

    /// Most cells this glyph may span.
    var maxConstraintWidth: UInt8 = 2

    var height: Height = .cell

    static let none = GlyphConstraint()

    /// A constraint that neither sizes nor moves anything can be skipped
    /// wholesale, which is the common case for Latin text.
    var doesAnything: Bool {
        size != .none || alignHorizontal != .none || alignVertical != .none
    }

    /// Apply this constraint given how many cells the glyph may occupy.
    func constrain(
        _ glyph: GlyphSize,
        metrics: GridMetrics,
        constraintWidth: UInt8
    ) -> GlyphSize {
        guard doesAnything else { return glyph }

        switch size {
        case .stretch:
            // Stretched glyphs exist to meet across cell boundaries, so they
            // want to be scaled and aligned to the pixel grid rather than to
            // the face. Lying about the metrics is the cheapest way to say
            // that.
            var m = metrics
            m.faceWidth = Double(m.cellWidth)
            m.faceHeight = Double(m.cellHeight)
            m.faceY = 0.0

            // Negative padding elsewhere papers over rounding gaps at the
            // cost of overlap artefacts. Aligned to the grid we don't need
            // it, so clamp it away.
            var c = self
            c.padBottom = max(0, c.padBottom)
            c.padTop = max(0, c.padTop)
            c.padLeft = max(0, c.padLeft)
            c.padRight = max(0, c.padRight)

            return c.constrainInner(glyph, metrics: m, constraintWidth: constraintWidth)

        default:
            return constrainInner(glyph, metrics: metrics, constraintWidth: constraintWidth)
        }
    }

    private func constrainInner(
        _ glyph: GlyphSize,
        metrics: GridMetrics,
        constraintWidth: UInt8
    ) -> GlyphSize {
        // Very wide faces never stretch a glyph across two cells. Mirrors
        // font-patcher.
        let minConstraintWidth: UInt8 =
            (size == .stretch && metrics.faceWidth > 0.9 * metrics.faceHeight)
            ? 1
            : min(maxConstraintWidth, constraintWidth)

        // The bounding box of this glyph's scale group. Rules are computed
        // for the group and then transferred back to the glyph.
        var group: GlyphSize = {
            let groupWidth = glyph.width / relativeWidth
            let groupHeight = glyph.height / relativeHeight
            return GlyphSize(
                width: groupWidth,
                height: groupHeight,
                x: glyph.x - (groupWidth * relativeX),
                y: glyph.y - (groupHeight * relativeY))
        }()

        // Scale about the group's centre.
        let (widthFactor, heightFactor) = scaleFactors(
            group: group, metrics: metrics, minConstraintWidth: minConstraintWidth)
        let centerX = group.x + (group.width / 2)
        let centerY = group.y + (group.height / 2)
        group.width *= widthFactor
        group.height *= heightFactor
        group.x = centerX - (group.width / 2)
        group.y = centerY - (group.height / 2)

        // font-patcher rounds to font design units here and works hard to
        // keep the glyph inside its box afterwards. We stay in Double all the
        // way to the rasterizer, so there is nothing to correct for.

        group.y = alignedY(group: group, metrics: metrics)
        group.x = alignedX(
            group: group, metrics: metrics, minConstraintWidth: minConstraintWidth)

        return GlyphSize(
            width: widthFactor * glyph.width,
            height: heightFactor * glyph.height,
            x: group.x + (group.width * relativeX),
            y: group.y + (group.height * relativeY))
    }

    private func scaleFactors(
        group: GlyphSize,
        metrics: GridMetrics,
        minConstraintWidth: UInt8
    ) -> (Double, Double) {
        if size == .none { return (1.0, 1.0) }

        let multiCell = minConstraintWidth > 1

        let padWidthFactor = Double(minConstraintWidth) - (padLeft + padRight)
        let padHeightFactor = 1 - (padBottom + padTop)

        let targetWidth = padWidthFactor * metrics.faceWidth
        let targetHeight =
            padHeightFactor
            * {
                switch height {
                case .cell: return metrics.faceHeight
                // As in font-patcher, the icon constraint height depends on
                // the constraint width.
                case .icon: return multiCell ? metrics.iconHeight : metrics.iconHeightSingle
                }
            }()

        var widthFactor = targetWidth / group.width
        var heightFactor = targetHeight / group.height

        switch size {
        case .none:
            break
        case .fit:
            heightFactor = min(1, widthFactor, heightFactor)
            widthFactor = heightFactor
        case .cover:
            heightFactor = min(widthFactor, heightFactor)
            widthFactor = heightFactor
        case .fitCover1:
            // Like font-patcher's "pa" mode, with one fix: font-patcher only
            // upscales when the constraint width is 1, so an icon would
            // *shrink* when a space opened up after it. We scale multi-cell
            // icons to the same size they'd get single-cell.
            heightFactor = min(widthFactor, heightFactor)
            if multiCell && heightFactor > 1 {
                // Recurse at width 1 for the single-cell factor. Use the
                // height factor: width may have been cut by maxXYRatio.
                let (_, singleHeightFactor) = scaleFactors(
                    group: group, metrics: metrics, minConstraintWidth: 1)
                heightFactor = max(1, singleHeightFactor)
            }
            widthFactor = heightFactor
        case .stretch:
            break
        }

        if let ratio = maxXYRatio {
            if group.width * widthFactor > group.height * heightFactor * ratio {
                widthFactor = group.height * heightFactor * ratio / group.width
            }
        }

        return (widthFactor, heightFactor)
    }

    private func alignedY(group: GlyphSize, metrics: GridMetrics) -> Double {
        if size == .none && alignVertical == .none {
            return group.y
        }
        // We work in face height offset by faceY rather than cell height
        // directly, because the pixel cell is asymmetric around the face:
        // the baseline is snapped to a pixel boundary, not centred.
        let padBottomDy = padBottom * metrics.faceHeight
        let padTopDy = padTop * metrics.faceHeight
        let startY = metrics.faceY + padBottomDy
        let endY = metrics.faceY + (metrics.faceHeight - group.height - padTopDy)
        let centerY = (startY + endY) / 2
        switch alignVertical {
        case .none:
            // Even with no alignment rule, every size rule implies the glyph
            // stays inside the padded cell. Falling back to centring when the
            // group is too tall is unreachable in practice, since .none here
            // means size != .none.
            return endY < startY ? centerY : max(startY, min(group.y, endY))
        case .start: return startY
        case .end: return endY
        case .center, .center1: return centerY
        }
    }

    private func alignedX(
        group: GlyphSize,
        metrics: GridMetrics,
        minConstraintWidth: UInt8
    ) -> Double {
        if size == .none && alignHorizontal == .none {
            return group.x
        }
        // Multi-cell glyphs align to the span from the left edge of the first
        // cell to the right edge of the last face cell, assuming it is
        // left-aligned in its rounded pixel cell. Re-centring the face within
        // the grid cell happens afterwards, in the rasterizer.
        let fullFaceSpan =
            metrics.faceWidth + Double(Int(minConstraintWidth - 1) * Int(metrics.cellWidth))
        let padLeftDx = padLeft * metrics.faceWidth
        let padRightDx = padRight * metrics.faceWidth
        let startX = padLeftDx
        let endX = fullFaceSpan - group.width - padRightDx
        switch alignHorizontal {
        case .none:
            return max(startX, min(group.x, endX))
        case .start: return startX
        case .end: return max(startX, endX)
        case .center: return max(startX, (startX + endX) / 2)
        case .center1:
            // font-patcher's rule: centre in the *first* cell even when the
            // constraint spans two. Since glyphs may not protrude left, a
            // glyph wider than a cell ends up left-aligned like .start.
            let end1X = metrics.faceWidth - group.width - padRightDx
            return max(startX, (startX + end1X) / 2)
        }
    }
}
