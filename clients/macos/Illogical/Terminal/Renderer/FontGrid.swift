//  FontGrid.swift
//  The set of faces a terminal draws from, plus their glyph atlases.
//
//  Ported from libghostty's `src/font/SharedGrid.zig`, `Collection.zig` and
//  `CodepointResolver.zig`, collapsed into one type because we don't need
//  their deferred-face machinery: CoreText already loads lazily.
//
//  Shared, not per-surface. A window with four splits is four renderers on
//  four threads, and they should be rasterizing into *one* pair of atlases —
//  otherwise the same 'e' is packed four times and every pane pays for its
//  own 256 KB texture. Sharing costs a reader-writer lock, and the read side
//  is the only one on the per-glyph path.

import CoreText
import Foundation

enum FontStyle: Int, CaseIterable, Hashable {
    case regular = 0
    case bold = 1
    case italic = 2
    case boldItalic = 3

    var isBold: Bool { self == .bold || self == .boldItalic }
    var isItalic: Bool { self == .italic || self == .boldItalic }
}

enum FontPresentation: Hashable {
    case text
    case emoji
}

/// Which face in the grid.
///
/// An index into one flat array of every face the grid has loaded. What a
/// given slot *is* — a configured family, the font we ship, something the
/// system cascade turned up — is `styleSlots`' business. The glyph cache is
/// keyed on this, so it stays a bare number.
struct FontIndex: Hashable {
    var slot: UInt16

    static let sprite = FontIndex(slot: .max)
    var isSprite: Bool { slot == .max }
}

/// A rasterized glyph plus which atlas it landed in.
struct GlyphRender {
    var glyph: Glyph
    var presentation: FontPresentation
}

/// Reader-writer lock. The glyph cache is read on every cell of every frame
/// from every renderer thread and written only when a new glyph appears, so
/// the read side must not serialize.
final class RWLock: @unchecked Sendable {
    private var lock = pthread_rwlock_t()

    init() { pthread_rwlock_init(&lock, nil) }
    deinit { pthread_rwlock_destroy(&lock) }

    func readLock() { pthread_rwlock_rdlock(&lock) }
    func writeLock() { pthread_rwlock_wrlock(&lock) }
    func unlock() { pthread_rwlock_unlock(&lock) }

    func withRead<T>(_ body: () throws -> T) rethrows -> T {
        readLock()
        defer { unlock() }
        return try body()
    }

    func withWrite<T>(_ body: () throws -> T) rethrows -> T {
        writeLock()
        defer { unlock() }
        return try body()
    }
}

final class FontGrid: @unchecked Sendable {
    /// Guards `faces`, both atlases, and both caches.
    let lock = RWLock()

    let atlasGrayscale: Atlas
    let atlasColor: Atlas

    /// Immutable after init: derived from the primary regular face.
    let metrics: GridMetrics

    /// That face's own measurements, kept because a fallback is scaled
    /// against them and `resolveLocked` discovers fallbacks long after init.
    private let primaryFaceMetrics: FaceMetrics

    /// The size faces are loaded at, before any per-face adjustment.
    private let pixelSize: Double
    let sprite: SpriteFace

    /// The fonts and display scale this grid was built for. Part of
    /// `FontGridSet`'s key: a grid is only shared by panes that agree on both.
    let font: FontConfig
    let scale: Double

    /// The point size this grid was built for.
    var pointSize: Double { font.pointSize }

    /// Every face the grid has loaded, in load order. Indexed by
    /// `FontIndex.slot`.
    private var faces: [FontFace]

    /// Which faces answer for each style, in the order they are searched:
    /// the configured families first, then the text font we ship behind
    /// them, then the Nerd Font symbols behind that. Indexed by
    /// `FontStyle.rawValue`, and never empty for any style.
    private var styleSlots: [[UInt16]]

    /// Faces the system cascade turned up, per style, in discovery order.
    /// Searched after `styleSlots` — a font the person named always wins over
    /// one we went looking for.
    private var discovered: [[UInt16]]

    /// Fallbacks discovered so far, keyed by PostScript name and style so the
    /// same font isn't loaded twice.
    private var fallbackSlots: [String: UInt16] = [:]

    private struct CodepointKey: Hashable {
        var cp: UInt32
        var style: FontStyle
        var presentation: FontPresentation?
    }
    private var codepointCache: [CodepointKey: FontIndex?] = [:]

    private struct GlyphKey: Hashable {
        var index: FontIndex
        var glyph: UInt32
        var options: GlyphRenderOptions
    }
    private var glyphCache: [GlyphKey: GlyphRender] = [:]

    /// Atlases start at 512. Big enough that a normal session never grows the
    /// grayscale one, small enough that an idle pane isn't carrying megabytes.
    private static let initialAtlasSize: UInt32 = 512

    init(font: FontConfig, scale: Double) {
        self.font = font
        self.scale = scale

        // CoreText is asked for the font at its *pixel* size, so all the
        // metrics come back in pixels and no scaling is needed downstream.
        pixelSize = font.pointSize * scale
        let built = Self.build(font: font, pixelSize: pixelSize)
        faces = built.faces
        styleSlots = built.styleSlots
        discovered = Array(repeating: [], count: FontStyle.allCases.count)

        // Measured once. It is both what the grid is derived from and what
        // every later fallback is scaled against, and `faceMetrics` reads
        // four OpenType tables to produce it.
        primaryFaceMetrics =
            built.faces[Int(built.styleSlots[FontStyle.regular.rawValue][0])].faceMetrics()
        metrics = GridMetrics.calc(primaryFaceMetrics)
        sprite = SpriteFace(metrics: metrics)

        atlasGrayscale = Atlas(size: Self.initialAtlasSize, format: .grayscale)
        atlasColor = Atlas(size: Self.initialAtlasSize, format: .bgra)
    }

    /// The named family, or nil when nothing on the system provides it.
    ///
    /// The nil is the point. `CTFontCreateWithFontDescriptor` cannot fail:
    /// handed a family nothing matches it returns Helvetica — proportional,
    /// so every cell would be measured off the wrong advance — rather than
    /// saying so. Matching first is what turns an uninstalled family into a
    /// miss, so `build` can fall through to the font we ship instead of
    /// quietly drawing the terminal in Helvetica.
    private static func font(named name: String, size: Double) -> CTFont? {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: name] as CFDictionary)
        // The family has to be mandatory, or the match is free to satisfy
        // none of it and we are back to Helvetica.
        let mandatory = Set([kCTFontFamilyNameAttribute as String]) as NSSet as CFSet
        guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, mandatory)
        else { return nil }
        return CTFontCreateWithFontDescriptor(matched, size, nil)
    }

    /// Every face the grid starts with, and which of them answers for each
    /// style.
    ///
    /// `SharedGridSet.zig`'s ordering, step for step, because each step is a
    /// decision that shows up as text drawn in the wrong typeface if it is
    /// skipped:
    ///
    /// 1. **The configured families, in order.** Each one is resolved and
    ///    then asked for the style — its own bold, or a synthesized one. A
    ///    family that is not installed is skipped rather than substituted.
    /// 2. **Styles that came out empty borrow the regular face.** This is
    ///    libghostty's `completeStyles`, and the rule it encodes is that a
    ///    style is never taken from another family: `font-family-bold` naming
    ///    something uninstalled falls back to `font-family` in bold, not to
    ///    the next family in the bold list.
    /// 3. **The text font we ship, behind all of it.** A fallback rather than
    ///    a default: a codepoint the configured family lacks is drawn from
    ///    ours before the system cascade is asked. libghostty adds it here for
    ///    the stated reason that "we want to ensure our built-in styles are
    ///    fallbacks to the configured styles".
    /// 4. **The system's fixed-pitch face, if there is nothing else.** Only
    ///    reachable in a build whose bundle lost its font resources.
    /// 5. **The Nerd Font symbols, behind everything.** One face, shared by
    ///    all four styles: icons have no bold or italic, and
    ///    `SharedGridSet.zig` adds the same file once, as regular, with no
    ///    size adjustment. After step 4 on purpose — `metrics` is read off
    ///    the first regular face, and a symbols-only font must never be the
    ///    face a grid measures its cells from.
    private static func build(
        font config: FontConfig, pixelSize: Double
    ) -> (faces: [FontFace], styleSlots: [[UInt16]]) {
        var faces: [FontFace] = []
        var slots: [[UInt16]] = Array(repeating: [], count: FontStyle.allCases.count)

        func append(_ face: FontFace, to style: FontStyle) {
            slots[style.rawValue].append(UInt16(faces.count))
            faces.append(face)
        }

        // 1. What the config named.
        for style in FontStyle.allCases {
            for family in config[style] {
                guard let named = font(named: family, size: pixelSize) else { continue }
                append(styled(named, style: style, size: pixelSize), to: style)
            }
        }

        // 2. Complete the styles from the regular family, never across
        //    families. Regular itself has nothing to borrow from.
        if let regular = slots[FontStyle.regular.rawValue].first.map({ faces[Int($0)] }) {
            for style in FontStyle.allCases where slots[style.rawValue].isEmpty {
                append(
                    derive(
                        regular.font, bold: style.isBold, italic: style.isItalic,
                        size: pixelSize, from: regular), to: style)
            }
        }

        // 3. The font we ship, behind whatever the config asked for.
        // Scaled to the configured family, if there is one. When there is
        // not, ours *is* the primary and the factor comes out 1.
        let primaryMetrics = slots[FontStyle.regular.rawValue].first.map {
            faces[Int($0)].faceMetrics()
        }
        if let builtin = builtinFaces(size: pixelSize, matching: primaryMetrics) {
            for style in FontStyle.allCases {
                append(builtin[style.rawValue], to: style)
            }
        }

        // 4. Nothing bundled, which in practice means a build that dropped
        //    the resources. Land on the system's fixed-pitch face rather than
        //    on nothing: `metrics` reads the first regular face, and every
        //    style has to answer.
        if slots.contains(where: \.isEmpty) {
            let system =
                CTFontCreateUIFontForLanguage(.userFixedPitch, pixelSize, nil)
                ?? CTFontCreateWithName("Menlo" as CFString, pixelSize, nil)
            for style in FontStyle.allCases where slots[style.rawValue].isEmpty {
                append(styled(system, style: style, size: pixelSize), to: style)
            }
        }

        // 5. The Nerd Font symbols, behind everything. A single slot that
        //    every style searches last, so an icon rasterized for regular
        //    text is the same atlas entry when it turns up in bold — and so
        //    a configured family that carries its own icons, a patched Nerd
        //    Font say, is still asked first.
        if let symbols = symbolsFace(size: pixelSize) {
            let slot = UInt16(faces.count)
            faces.append(symbols)
            for style in FontStyle.allCases { slots[style.rawValue].append(slot) }
        }

        return (faces, slots)
    }

    /// One family's face for one style: the family's own, or synthesized from
    /// it. Regular is the family itself, with nothing asked of it — asking
    /// CoreText for "no traits" is a match that can come back with a face the
    /// family did not intend.
    private static func styled(_ base: CTFont, style: FontStyle, size: Double) -> FontFace {
        let regular = FontFace(font: base)
        guard style != .regular else { return regular }
        return derive(
            base, bold: style.isBold, italic: style.isItalic, size: size, from: regular)
    }

    /// The font we ship, in the four styles, or nil when it is not in the
    /// bundle.
    ///
    /// This is `SharedGridSet.zig`'s arrangement exactly. Two variable files
    /// cover four styles: bold is the upright face with the `wght` axis at
    /// 700, bold-italic the italic face with the same. libghostty embeds the
    /// four static faces as well and then does not use them, and the reason
    /// shows up here — a variable face carries every weight between 100 and
    /// 800, so a static bold would only be a second copy of one of them.
    ///
    /// Italic does need its own file. `derive` cannot reach it: JetBrains
    /// Mono ships italic separately, and asking CoreText for the italic
    /// trait on the upright variable face returns the upright face, which
    /// would quietly leave every italic cell synthetically skewed.
    /// `matching` is the face this one sits behind, or nil when nothing was
    /// configured and ours is the primary. libghostty adds all four of these
    /// with `default_fallback_adjustment`, which is `.ic_width`.
    private static func builtinFaces(
        size: Double, matching primary: FaceMetrics?
    ) -> [FontFace]? {
        guard let upright = EmbeddedFont.variable,
            let slanted = EmbeddedFont.variableItalic
        else { return nil }

        // The faces are parsed once at a nominal size and copied to the size
        // wanted here, which is libghostty's `initFontCopy`.
        func sized(_ base: CTFont) -> FontFace {
            FontFace(
                font: CTFontCreateCopyWithAttributes(
                    base, adjusted(size, of: base, to: primary, by: .icWidth), nil, nil))
        }

        let regular = sized(upright)
        let italic = sized(slanted)
        let bold = EmbeddedFont.boldWeight
        let axis = EmbeddedFont.weightAxis
        // The two varied faces inherit the adjusted size: `withVariation`
        // copies at size 0, which keeps whatever size the face already has.
        return [
            regular,
            regular.withVariation(axis: axis, value: bold),
            italic,
            italic.withVariation(axis: axis, value: bold),
        ]
    }

    /// The size to load `base` at so it sits with `primary`.
    ///
    /// Measuring costs four OpenType table reads, so this is only reached for
    /// a face that is actually being added — never on the per-glyph path.
    /// A nil `primary` means there is nothing to match yet, which happens for
    /// the very first face in the grid.
    private static func adjusted(
        _ size: Double, of base: CTFont, to primary: FaceMetrics?, by adjustment: SizeAdjustment
    ) -> Double {
        guard let primary, adjustment != .none else { return size }
        let candidate = FontFace(font: CTFontCreateCopyWithAttributes(base, size, nil, nil))
        return size
            * FaceMetrics.scaleFactor(
                primary: primary, face: candidate.faceMetrics(), adjustment: adjustment)
    }

    /// The Nerd Font symbols at this size, or nil when the file is not in
    /// the bundle.
    ///
    /// No size adjustment, as in `SharedGridSet.zig`. This is the unpatched
    /// symbols file, so fitting each icon to its cell is `NerdFontConstraints`'
    /// job at render time — the patcher's own per-icon arithmetic, which no
    /// single scale factor could stand in for on a face whose glyphs were
    /// drawn at wildly different natural sizes.
    private static func symbolsFace(size: Double) -> FontFace? {
        guard let symbols = EmbeddedFont.symbols else { return nil }
        return FontFace(font: CTFontCreateCopyWithAttributes(symbols, size, nil, nil))
    }

    /// Derive a styled face, synthesizing whatever the family doesn't have.
    ///
    /// A real bold beats a stroked one every time, but plenty of monospace
    /// families ship regular only and italic-less families are common.
    private static func derive(
        _ base: CTFont, bold: Bool, italic: Bool, size: Double, from regular: FontFace
    ) -> FontFace {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }

        if let real = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) {
            let face = FontFace(font: real)
            // Ask for what we got: the copy succeeds even when the family
            // has no such face, so check the traits actually took.
            let got = CTFontGetSymbolicTraits(real)
            let haveBold = got.contains(.traitBold)
            let haveItalic = got.contains(.traitItalic)
            if haveBold == bold && haveItalic == italic { return face }

            // Partial match: keep the real face and synthesize the rest.
            var result = face
            if italic && !haveItalic { result = result.syntheticItalic() }
            if bold && !haveBold { result = result.syntheticBoldCopy() }
            return result
        }

        var result = regular
        if italic { result = result.syntheticItalic() }
        if bold { result = result.syntheticBoldCopy() }
        return result
    }

    func face(_ index: FontIndex) -> FontFace? {
        guard !index.isSprite, Int(index.slot) < faces.count else { return nil }
        return faces[Int(index.slot)]
    }

    /// The face a style is drawn with when the codepoint needs no fallback:
    /// the first family that was configured for it, or the font we ship.
    ///
    /// Never nil — `build` guarantees every style has at least one face — but
    /// optional anyway, because the alternative is a subscript that traps if
    /// that guarantee is ever broken.
    func face(style: FontStyle) -> FontFace? {
        faces(style: style).first
    }

    /// Every face a style will be searched through, in order, before the
    /// system cascade is asked.
    ///
    /// That order *is* the font configuration's behaviour — the families
    /// somebody named, in the order they named them, and the fonts we ship
    /// behind all of them — and it is invisible from the outside otherwise: a
    /// grid that dropped the fallbacks still draws every ordinary character
    /// correctly.
    func faces(style: FontStyle) -> [FontFace] {
        lock.withRead { styleSlots[style.rawValue].map { faces[Int($0)] } }
    }

    // MARK: - Codepoint resolution

    /// Which face should render this codepoint, or nil if nothing can.
    ///
    /// Sprites win over fonts: we draw box drawing and blocks ourselves even
    /// when the font has them, because ours tile and the font's do not.
    func index(
        codepoint cp: UInt32, style: FontStyle, presentation: FontPresentation?
    ) -> FontIndex? {
        let key = CodepointKey(cp: cp, style: style, presentation: presentation)

        if let cached = lock.withRead({ codepointCache[key] }) { return cached }

        lock.writeLock()
        defer { lock.unlock() }
        if let cached = codepointCache[key] { return cached }

        let resolved = resolveLocked(cp: cp, style: style, presentation: presentation)
        codepointCache[key] = resolved
        return resolved
    }

    /// Caller must hold the write lock.
    private func resolveLocked(
        cp: UInt32, style: FontStyle, presentation: FontPresentation?
    ) -> FontIndex? {
        // Sprites first. Emoji presentation was explicitly asked for means
        // the caller wants a colour glyph, which we never draw.
        if presentation != .emoji, SpriteFace.hasCodepoint(cp) {
            return .sprite
        }

        let wantEmoji = presentation == .emoji

        // The faces this style was built with, in order: every family the
        // config named, then the text font we ship, then the Nerd Font
        // symbols. First one that has the codepoint wins, which is what makes
        // `font-family` repeating a fallback list rather than four ways to
        // say the same thing.
        //
        // Never for an explicit emoji request — none of these carry colour
        // glyphs, and asking the cascade is the whole point of that request.
        let primary = faces[Int(styleSlots[style.rawValue][0])]
        if !wantEmoji {
            for slot in styleSlots[style.rawValue] {
                if let g = faces[Int(slot)].glyphIndex(cp), g != 0 {
                    return FontIndex(slot: slot)
                }
            }
        }

        // Anything the cascade already turned up for this style.
        for slot in discovered[style.rawValue] {
            let face = faces[Int(slot)]
            if wantEmoji && !face.hasColor { continue }
            if let g = face.glyphIndex(cp), g != 0 {
                return FontIndex(slot: slot)
            }
        }

        // Ask the system. CTFontCreateForString walks the platform's own
        // cascade list, which is a better fallback chain than anything we'd
        // assemble by hand.
        guard let scalar = Unicode.Scalar(cp) else { return nil }
        var text = String(scalar)
        // The emoji variation selector steers the cascade toward a colour
        // font, which is exactly how we express "explicit emoji".
        if wantEmoji { text.append("\u{FE0F}") }
        let cf = text as CFString
        let fallback = CTFontCreateForString(
            primary.font, cf, CFRangeMake(0, CFStringGetLength(cf)))

        let name = (CTFontCopyPostScriptName(fallback) as String?) ?? ""
        let dedupeKey = "\(name)|\(style.rawValue)"
        if let slot = fallbackSlots[dedupeKey] {
            let face = faces[Int(slot)]
            if let g = face.glyphIndex(cp), g != 0 { return FontIndex(slot: slot) }
            return nil
        }

        // Scaled to the primary face. Without this a CJK fallback at the
        // same point size renders visibly larger or smaller than the Latin
        // text beside it, which is the whole reason libghostty adds every
        // discovered fallback with `default_fallback_adjustment`.
        //
        // Colour faces are exempt. Apple Color Emoji is a bitmap strike with
        // no ideographs and an ex height that has nothing to do with text,
        // so a factor computed from it would resize emoji for no reason;
        // libghostty passes `.none` for the emoji font too.
        let unscaled = FontFace(font: fallback)
        let face =
            unscaled.hasColor
            ? unscaled
            : FontFace(
                font: CTFontCreateCopyWithAttributes(
                    fallback,
                    Self.adjusted(
                        pixelSize, of: fallback, to: primaryFaceMetrics, by: .icWidth),
                    nil, nil))
        guard let g = face.glyphIndex(cp), g != 0 else { return nil }

        let slot = UInt16(faces.count)
        faces.append(face)
        // Per style, because the cascade was asked starting from *this*
        // style's face: the CJK face it returns for bold is the bold one, and
        // filing it under regular as well would draw bold CJK at regular
        // weight the next time it came up.
        discovered[style.rawValue].append(slot)
        fallbackSlots[dedupeKey] = slot
        return FontIndex(slot: slot)
    }

    /// Whether a specific face can render a codepoint. Used when checking
    /// that one face covers an entire grapheme cluster.
    func hasCodepoint(
        _ index: FontIndex, _ cp: UInt32, _ presentation: FontPresentation?
    )
        -> Bool
    {
        if index.isSprite { return SpriteFace.hasCodepoint(cp) }
        return lock.withRead {
            guard Int(index.slot) < faces.count else { return false }
            let face = faces[Int(index.slot)]
            if presentation == .emoji && !face.hasColor { return false }
            guard let g = face.glyphIndex(cp) else { return false }
            return g != 0
        }
    }

    // MARK: - Glyph rasterization

    /// Rasterize (or fetch from cache) one glyph.
    ///
    /// The fast path is a read lock and a dictionary hit, which is where
    /// essentially every call lands once a screen's worth of text has been
    /// drawn once.
    func renderGlyph(
        _ index: FontIndex, glyph glyphIndex: UInt32, options: GlyphRenderOptions
    ) throws -> GlyphRender {
        let key = GlyphKey(index: index, glyph: glyphIndex, options: options)

        if let hit = lock.withRead({ glyphCache[key] }) { return hit }

        lock.writeLock()
        defer { lock.unlock() }
        if let hit = glyphCache[key] { return hit }

        let render = try renderLocked(index, glyphIndex, options)
        glyphCache[key] = render
        return render
    }

    /// Caller must hold the write lock.
    private func renderLocked(
        _ index: FontIndex, _ glyphIndex: UInt32, _ options: GlyphRenderOptions
    ) throws -> GlyphRender {
        if index.isSprite {
            let glyph = try withAtlasGrowth(atlasGrayscale) {
                try sprite.render(codepoint: glyphIndex, into: atlasGrayscale, options: options)
            }
            return GlyphRender(glyph: glyph, presentation: .text)
        }

        guard Int(index.slot) < faces.count else {
            return GlyphRender(glyph: Glyph(), presentation: .text)
        }
        let face = faces[Int(index.slot)]

        let presentation: FontPresentation = face.isColorGlyph(glyphIndex) ? .emoji : .text
        let atlas = presentation == .emoji ? atlasColor : atlasGrayscale

        var opts = options
        if presentation == .emoji { opts.constraintKind = .emoji }

        let glyph = try withAtlasGrowth(atlas) {
            try face.render(
                glyphIndex: glyphIndex, into: atlas, metrics: metrics, options: opts)
        }
        return GlyphRender(glyph: glyph, presentation: presentation)
    }

    /// Largest atlas we will grow to. Comfortably inside every Metal
    /// device's maximum texture size, and far past what a session needs:
    /// 8192x8192 grayscale holds tens of thousands of glyphs.
    private static let maxAtlasSize: UInt32 = 8192

    /// Run `body`, doubling the atlas until it fits.
    ///
    /// One retry isn't always enough — a single glyph at a very large font
    /// size can be bigger than the whole atlas — so this keeps doubling. If
    /// it hits the cap the error propagates and the caller drops the glyph,
    /// which is the right failure: a missing glyph, not a crash.
    private func withAtlasGrowth(_ atlas: Atlas, _ body: () throws -> Glyph) throws -> Glyph {
        while true {
            do {
                return try body()
            } catch AtlasError.full {
                guard atlas.size < Self.maxAtlasSize else { throw AtlasError.full }
                atlas.grow(to: min(atlas.size * 2, Self.maxAtlasSize))
            }
        }
    }

    /// Rasterize a codepoint directly, resolving the face first. Used for
    /// glyphs the renderer needs by codepoint rather than by shaped index,
    /// such as the password-input lock cursor.
    func renderCodepoint(
        _ cp: UInt32, style: FontStyle, presentation: FontPresentation?,
        options: GlyphRenderOptions
    ) -> GlyphRender? {
        guard let index = index(codepoint: cp, style: style, presentation: presentation)
        else { return nil }
        let glyphIndex: UInt32
        if index.isSprite {
            glyphIndex = cp
        } else {
            guard let face = lock.withRead({ self.face(index) }),
                let g = face.glyphIndex(cp)
            else { return nil }
            glyphIndex = g
        }
        return try? renderGlyph(index, glyph: glyphIndex, options: options)
    }
}

/// Process-wide registry of grids, so panes with the same font share one.
enum FontGridSet {
    private struct Key: Hashable {
        var font: FontConfig
        var scale: Double
    }

    private static let lock = NSLock()
    // Guarded by `lock`; the compiler can't see that, hence the annotation.
    nonisolated(unsafe) private static var grids: [Key: FontGrid] = [:]

    static func grid(font: FontConfig, scale: Double) -> FontGrid {
        let key = Key(font: font, scale: scale)
        lock.lock()
        defer { lock.unlock() }
        if let existing = grids[key] { return existing }
        let grid = FontGrid(font: font, scale: scale)
        grids[key] = grid
        return grid
    }

    /// One family for every style. What the tests want, and it keeps them
    /// from having to spell out four identical lists to say "Menlo".
    static func grid(family: String?, pointSize: Double, scale: Double) -> FontGrid {
        grid(font: FontConfig(family: family, pointSize: pointSize), scale: scale)
    }
}
