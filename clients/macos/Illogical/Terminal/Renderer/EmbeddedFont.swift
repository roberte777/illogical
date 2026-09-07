//  EmbeddedFont.swift
//  The fonts that ship inside the app bundle.
//
//  Ported from libghostty's `src/font/embedded.zig`, which embeds JetBrains
//  Mono into the binary so a fresh install looks right without the user
//  installing anything. Zig has `@embedFile`; a Mac app has bundle
//  resources, so the bytes live in `Contents/Resources` instead of in
//  `__TEXT` — but everything downstream is the same, and deliberately so:
//
//  - The bytes are turned into a face with
//    `CTFontManagerCreateFontDescriptorFromData`, which is the singular call
//    libghostty's `face/coretext.zig` makes. It hands back the font's
//    *default* instance. The plural `...DescriptorsFrom{Data,URL}` enumerate
//    a variable font's named instances instead, and the first of those is
//    Thin, not Regular — a quiet way to ship the wrong weight.
//  - Nothing is ever registered with `CTFontManager`. The faces are private
//    to this process and never appear in the user's font list.
//
//  See `Supporting/Fonts/README.md` for where the files came from and what
//  they are licensed under.

import CoreText
import Foundation

enum EmbeddedFont {
    /// The default family: JetBrains Mono, upright and italic, both variable.
    ///
    /// Bold is not a third file. libghostty pins the `wght` axis to 700 on
    /// these same two faces, so the bundle carries two files where a static
    /// family would need four.
    static var variable: CTFont? { font(.variable) }
    static var variableItalic: CTFont? { font(.variableItalic) }

    /// One embedded face, at the nominal size. The two properties above are
    /// what the grid asks for by name; this is what a test walking
    /// `Resource.allCases` uses, so that conformance stays honest as more
    /// faces are embedded.
    static func font(_ resource: Resource) -> CTFont? { load(resource) }

    /// The `wght` OpenType variation axis, as a four-byte tag. 700 is bold.
    static let weightAxis: UInt32 = 0x7767_6874  // 'wght'
    static let boldWeight: Double = 700

    enum Resource: String, CaseIterable {
        case variable = "JetBrainsMono[wght]"
        case variableItalic = "JetBrainsMono-Italic[wght]"
    }

    /// Faces are created at a nominal size and copied to the size actually
    /// wanted, the way libghostty's `initFontCopy` does. Caching them here
    /// means the ~300 KB of each file is parsed once per process rather than
    /// once per font grid, and a grid is built per display scale and size.
    private static let cacheLock = NSLock()
    // Guarded by `cacheLock`; the compiler can't see that, hence the
    // annotation.
    nonisolated(unsafe) private static var cache: [Resource: CTFont?] = [:]

    /// The size faces are parsed at. Arbitrary — every caller copies to its
    /// own pixel size — but it matches libghostty's, which uses 12.
    private static let nominalSize: CGFloat = 12

    private static func load(_ resource: Resource) -> CTFont? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[resource] { return hit }
        let font = parse(resource)
        cache[resource] = font
        return font
    }

    private static func parse(_ resource: Resource) -> CTFont? {
        // `Bundle(for:)` rather than `.main`: the renderer's sources are
        // compiled into the unit-test bundle too, and there the fonts are
        // the test bundle's resources, not the host app's. No subdirectory —
        // Xcode's resources phase flattens the copy, so `Supporting/Fonts/`
        // is a source-tree layout and not a bundle one.
        guard
            let url = Bundle(for: FontFace.self).url(
                forResource: resource.rawValue, withExtension: "ttf"),
            // Mapped rather than read: CoreText holds these bytes for as
            // long as the face lives, which is the life of the process, and
            // mapped pages are file-backed and evictable where a read is
            // 300 KB of dirty memory that never comes back.
            let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData)
        else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, nominalSize, nil)
    }
}
