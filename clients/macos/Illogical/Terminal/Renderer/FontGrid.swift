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

/// Which face in the grid. Slots 0-3 are the primary family's styles;
/// anything above that is a fallback discovered for some codepoint.
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
    let sprite: SpriteFace

    /// The point size and display scale this grid was built for.
    let pointSize: Double
    let scale: Double

    private var faces: [FontFace]
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

    init(family: String?, pointSize: Double, scale: Double) {
        self.pointSize = pointSize
        self.scale = scale

        // CoreText is asked for the font at its *pixel* size, so all the
        // metrics come back in pixels and no scaling is needed downstream.
        let pixelSize = pointSize * scale

        faces = Self.primaryFaces(family: family, pixelSize: pixelSize)

        metrics = GridMetrics.calc(faces[FontStyle.regular.rawValue].faceMetrics())
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
    /// miss, so `primaryFaces` can fall through to the font we ship instead
    /// of quietly drawing the terminal in Helvetica.
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

    /// The four styles of the primary family, in `FontStyle` order.
    ///
    /// A named family wins, then the font we ship, then whatever the system
    /// calls fixed-pitch. The first two of those are libghostty's ordering:
    /// `SharedGridSet.zig` adds its built-in faces only after completing the
    /// configured ones, so a configured font always wins.
    ///
    /// Where this stops short of it is that libghostty *keeps* the built-in
    /// behind a configured family as a per-style fallback, so a codepoint
    /// the user's font lacks is drawn from ours before the system cascade is
    /// asked. Our fallback slots carry no style, so that belongs with the
    /// configurable font list rather than here (#42).
    private static func primaryFaces(family: String?, pixelSize: Double) -> [FontFace] {
        if let family, let named = font(named: family, size: pixelSize) {
            return derivedFaces(named, size: pixelSize)
        }
        if let builtin = builtinFaces(size: pixelSize) { return builtin }
        // Nothing bundled, which in practice means a build that dropped the
        // resources. Land on the system's fixed-pitch face rather than on
        // nothing.
        let system =
            CTFontCreateUIFontForLanguage(.userFixedPitch, pixelSize, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, pixelSize, nil)
        return derivedFaces(system, size: pixelSize)
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
    private static func builtinFaces(size: Double) -> [FontFace]? {
        guard let upright = EmbeddedFont.variable,
            let slanted = EmbeddedFont.variableItalic
        else { return nil }

        // The faces are parsed once at a nominal size and copied to the size
        // wanted here, which is libghostty's `initFontCopy`.
        let regular = FontFace(font: CTFontCreateCopyWithAttributes(upright, size, nil, nil))
        let italic = FontFace(font: CTFontCreateCopyWithAttributes(slanted, size, nil, nil))
        let bold = EmbeddedFont.boldWeight
        let axis = EmbeddedFont.weightAxis
        return [
            regular,
            regular.withVariation(axis: axis, value: bold),
            italic,
            italic.withVariation(axis: axis, value: bold),
        ]
    }

    /// The four styles of one face, synthesizing whatever the family lacks.
    private static func derivedFaces(_ base: CTFont, size: Double) -> [FontFace] {
        let regular = FontFace(font: base)
        return [
            regular,
            derive(base, bold: true, italic: false, size: size, from: regular),
            derive(base, bold: false, italic: true, size: size, from: regular),
            derive(base, bold: true, italic: true, size: size, from: regular),
        ]
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

        // The primary family in the requested style.
        let primary = faces[style.rawValue]
        if !wantEmoji, let g = primary.glyphIndex(cp), g != 0 {
            return FontIndex(slot: UInt16(style.rawValue))
        }

        // Any fallback we already discovered.
        for (slot, face) in faces.enumerated().dropFirst(FontStyle.allCases.count) {
            if wantEmoji && !face.hasColor { continue }
            if let g = face.glyphIndex(cp), g != 0 {
                return FontIndex(slot: UInt16(slot))
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

        let face = FontFace(font: fallback)
        guard let g = face.glyphIndex(cp), g != 0 else { return nil }

        let slot = UInt16(faces.count)
        faces.append(face)
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
        var family: String?
        var pointSize: Double
        var scale: Double
    }

    private static let lock = NSLock()
    // Guarded by `lock`; the compiler can't see that, hence the annotation.
    nonisolated(unsafe) private static var grids: [Key: FontGrid] = [:]

    static func grid(family: String?, pointSize: Double, scale: Double) -> FontGrid {
        let key = Key(family: family, pointSize: pointSize, scale: scale)
        lock.lock()
        defer { lock.unlock() }
        if let existing = grids[key] { return existing }
        let grid = FontGrid(family: family, pointSize: pointSize, scale: scale)
        grids[key] = grid
        return grid
    }
}
