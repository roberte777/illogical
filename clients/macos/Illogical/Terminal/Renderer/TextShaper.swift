//  TextShaper.swift
//  Turning a row of cells into positioned glyphs.
//
//  Ported from libghostty's `src/font/shaper/run.zig` and
//  `src/font/shaper/coretext.zig`.
//
//  Shaping is what makes ligatures, combining marks and non-Latin scripts
//  work, and it used to be 96% of libghostty's frame time before they cached
//  it. So this file is two things: a run iterator that splits a row at every
//  boundary where shaping must restart, and a cache keyed on a hash of the
//  run's contents so that redrawing the same text never shapes it twice.
//
//  The run hash is position-independent — clusters are relative to the start
//  of the run — so the same word shaped at column 3 and column 40 shares one
//  cache entry.

import CoreText
import Foundation

/// One glyph placed relative to the grid.
struct ShapedCell {
    /// Column within the row.
    var x: UInt16
    /// Offset from the cell origin, in pixels, from shaping.
    var xOffset: Int16 = 0
    var yOffset: Int16 = 0
    var glyphIndex: UInt32
}

/// A maximal span of one row that can be shaped as a unit.
struct TextRun {
    /// Content hash, used as the cache key. Collisions would mis-render but
    /// not corrupt anything, which is the tradeoff libghostty makes too.
    var hash: UInt64
    /// Column where the run starts.
    var offset: UInt16
    /// Cells the run covers.
    var count: UInt16
    var fontIndex: FontIndex

    /// Where this run's codepoints live in the shaper's row buffers.
    ///
    /// libghostty's iterator hands back one run at a time and the caller
    /// shapes it before asking for the next, so a single buffer suffices
    /// there. We collect every run for a row first — it makes the merge
    /// against cell positions much clearer — which means each run has to
    /// remember its own slice rather than share one.
    var codepointStart: Int
    var codepointCount: Int
}

/// Fixed-size, set-associative cache of shaped runs.
///
/// A dictionary with an LRU list would allocate on every insertion and touch
/// three cache lines per lookup. This is 256 buckets of 8, with random
/// eviction within a bucket — the same shape libghostty uses, for the same
/// reason: bounded memory and no per-frame allocation.
private final class ShapeCache {
    private static let buckets = 256
    private static let ways = 8

    private var keys: [UInt64]
    private var values: [[ShapedCell]?]
    private var rng: UInt64 = 0x2545_F491_4F6C_DD1D

    init() {
        keys = [UInt64](repeating: 0, count: Self.buckets * Self.ways)
        values = [[ShapedCell]?](repeating: nil, count: Self.buckets * Self.ways)
    }

    private func bucket(_ hash: UInt64) -> Int {
        Int(hash % UInt64(Self.buckets)) * Self.ways
    }

    func get(_ hash: UInt64) -> [ShapedCell]? {
        let base = bucket(hash)
        for i in base..<(base + Self.ways) where keys[i] == hash {
            return values[i]
        }
        return nil
    }

    func put(_ hash: UInt64, _ cells: [ShapedCell]) {
        let base = bucket(hash)
        // Prefer a free slot, or one already holding this key.
        for i in base..<(base + Self.ways) where values[i] == nil || keys[i] == hash {
            keys[i] = hash
            values[i] = cells
            return
        }
        // Otherwise evict at random. Random beats LRU here because the
        // bookkeeping LRU needs costs more than the hit rate it buys at
        // eight ways.
        rng ^= rng << 13
        rng ^= rng >> 7
        rng ^= rng << 17
        let i = base + Int(rng % UInt64(Self.ways))
        keys[i] = hash
        values[i] = cells
    }

    func clear() {
        for i in values.indices { values[i] = nil }
    }
}

final class TextShaper {
    private let grid: FontGrid

    /// Reused across rows so shaping allocates nothing per frame.
    private var codepoints: [(cp: UInt32, cluster: UInt32)] = []
    private var unichars: [UniChar] = []
    private var cellBuf: [ShapedCell] = []
    private var runBuf: [TextRun] = []

    private let cache = ShapeCache()

    /// Attribute dictionaries per font slot, so we aren't rebuilding a
    /// CFDictionary for every run.
    private var attrCache: [UInt16: CFDictionary] = [:]

    /// Resolved face for every ASCII codepoint, per style.
    ///
    /// `FontGrid.index` is correct and already cached, but it takes a reader
    /// lock and hashes a key, and the run iterator calls it *once per cell*.
    /// At ten thousand cells a frame that is measurable. The shaper belongs
    /// to one renderer on one thread, so it can put an unsynchronized array
    /// in front for the case that is essentially all of them.
    ///
    /// Only for the default presentation: a variation selector goes the slow
    /// way, as it should.
    private var asciiIndex = [FontIndex?](repeating: nil, count: 128 * 4)
    private var asciiResolved = [Bool](repeating: false, count: 128 * 4)

    private func fontIndex(
        _ cp: UInt32, _ style: FontStyle, _ presentation: FontPresentation?
    ) -> FontIndex? {
        guard presentation == nil, cp < 128 else {
            return grid.index(codepoint: cp, style: style, presentation: presentation)
        }
        let slot = Int(cp) * 4 + style.rawValue
        if asciiResolved[slot] { return asciiIndex[slot] }
        let resolved = grid.index(codepoint: cp, style: style, presentation: nil)
        asciiIndex[slot] = resolved
        asciiResolved[slot] = true
        return resolved
    }

    /// Forces left-to-right so CoreText doesn't reorder our runs. The
    /// terminal grid is already in visual order.
    private let typesetterOptions: CFDictionary = {
        let level = 0 as CFNumber
        return [kCTTypesetterOptionForcedEmbeddingLevel as String: level] as CFDictionary
    }()

    init(grid: FontGrid) {
        self.grid = grid
        codepoints.reserveCapacity(256)
        unichars.reserveCapacity(256)
        cellBuf.reserveCapacity(256)
        runBuf.reserveCapacity(64)
    }

    func clearCache() {
        cache.clear()
        attrCache.removeAll(keepingCapacity: true)
        for i in asciiResolved.indices { asciiResolved[i] = false }
    }

    // MARK: - Run iteration

    /// Split a row into runs.
    ///
    /// The returned array is a buffer owned by the shaper and is invalidated
    /// by the next call.
    func runs(
        row: [RenderCell],
        graphemes: [UInt32],
        cols: Int,
        selection: (start: UInt16, end: UInt16)?,
        cursorX: UInt16?
    ) -> [TextRun] {
        runBuf.removeAll(keepingCapacity: true)
        codepoints.removeAll(keepingCapacity: true)
        unichars.removeAll(keepingCapacity: true)

        // Trailing empty cells shape to nothing, so stop early. On a mostly
        // blank screen this is the difference between shaping 80 columns and
        // shaping 3.
        var maxCol = 0
        for i in stride(from: min(row.count, cols) - 1, through: 0, by: -1)
        where !row[i].isEmpty {
            maxCol = i + 1
            break
        }

        var i = 0
        while i < maxCol {
            // Invisible cells produce no glyphs at all.
            while i < maxCol && row[i].hasStyling && row[i].flags.contains(.invisible) {
                i += 1
            }
            guard i < maxCol else { break }

            if let run = nextRun(
                row: row, graphemes: graphemes, start: &i, maxCol: maxCol,
                selection: selection, cursorX: cursorX)
            {
                runBuf.append(run)
            } else {
                break
            }
        }

        return runBuf
    }

    private func nextRun(
        row: [RenderCell],
        graphemes: [UInt32],
        start: inout Int,
        maxCol: Int,
        selection: (start: UInt16, end: UInt16)?,
        cursorX: UInt16?
    ) -> TextRun? {
        let i = start
        let codepointStart = codepoints.count

        var hasher = RunHasher()

        // The run's style is the style of its first cell.
        let runCell = row[i]
        let fontStyle = runCell.hasStyling ? runCell.flags.fontStyle : .regular

        var currentFont: FontIndex? = nil
        var j = i

        while j < maxCol {
            let cell = row[j]
            // Clusters are relative to the run start, which is what makes
            // the hash position-independent.
            let cluster = UInt32(j - i)

            // A selection boundary splits the run: the two sides get
            // different colours, and a ligature spanning the boundary would
            // have to be one colour or the other.
            if let sel = selection, j > i {
                if sel.start > 0 && j == Int(sel.start) { break }
                if sel.end > 0 && j == Int(sel.end) + 1 { break }
            }

            // Spacers carry no glyph of their own.
            if cell.wide == .spacerHead || cell.wide == .spacerTail {
                j += 1
                continue
            }

            // A style change splits the run, so that ">=" whose halves are
            // coloured differently doesn't ligate into one colour.
            if j > i {
                let prev = row[j - 1]

                // Except for a few notoriously bad ligatures, which we split
                // unconditionally rather than let the font join them.
                var badLigature = false
                if prev.hasText && cell.hasText {
                    switch prev.codepoint {
                    case UInt32(UInt8(ascii: "f")):
                        let cp = cell.codepoint
                        badLigature =
                            cp == UInt32(UInt8(ascii: "l")) || cp == UInt32(UInt8(ascii: "i"))
                    case UInt32(UInt8(ascii: "s")):
                        badLigature = cell.codepoint == UInt32(UInt8(ascii: "t"))
                    default:
                        break
                    }
                }

                if !badLigature && !runCell.shapingEqual(cell) { break }
            }

            // The presentation the cell explicitly asks for, if any. Only the
            // first grapheme codepoint can carry a variation selector.
            var presentation: FontPresentation? = nil
            if cell.graphemeLen > 0 {
                let first = graphemes[Int(cell.graphemeOffset)]
                if first == 0xFE0E { presentation = .text }
                if first == 0xFE0F { presentation = .emoji }
            }

            // Break the run around the cursor, so the cell under a block
            // cursor can be recoloured independently of its neighbours. A
            // row with a cursor therefore has at least three runs. We don't
            // break a grapheme itself, so hovering an emoji is fine while
            // hovering its joiners still shows them.
            if cell.graphemeLen == 0, let cx = cursorX.map(Int.init) {
                // Exactly the cursor, after one iteration.
                if i == cx && j == i + 1 { break }
                // Up to but not including the cursor.
                if i < cx && j == cx { break }
                // After the cursor: nothing special, let the run finish.
            }

            // Find a face that covers the whole grapheme.
            let resolved = indexForCell(
                cell: cell, graphemes: graphemes, style: fontStyle,
                presentation: presentation)

            let resolvedIndex: FontIndex
            var fallbackCp: UInt32? = nil
            if let idx = resolved {
                resolvedIndex = idx
            } else if let idx = self.fontIndex(0xFFFD, fontStyle, presentation) {
                // Prefer the official replacement character.
                resolvedIndex = idx
                fallbackCp = 0xFFFD
            } else if let idx = self.fontIndex(0x20, fontStyle, presentation) {
                resolvedIndex = idx
                fallbackCp = 0x20
            } else {
                // Nothing can render even a space. Give up on this cell.
                j += 1
                continue
            }

            if j == i { currentFont = resolvedIndex }
            if resolvedIndex != currentFont { break }

            if let cp = fallbackCp {
                addCodepoint(&hasher, cp, cluster)
                j += 1
                continue
            }

            addCodepoint(&hasher, cell.codepoint == 0 ? 0x20 : cell.codepoint, cluster)
            if cell.graphemeLen > 0 {
                let base = Int(cell.graphemeOffset)
                for k in 0..<Int(cell.graphemeLen) {
                    let cp = graphemes[base + k]
                    // Presentation modifiers steer font selection but must
                    // not reach the shaper.
                    if cp == 0xFE0E || cp == 0xFE0F { continue }
                    addCodepoint(&hasher, cp, cluster)
                }
            }

            j += 1
        }

        guard let font = currentFont, j > i else {
            // Nothing shapeable here; make sure we still advance, and drop
            // whatever partial codepoints we accumulated.
            codepoints.removeLast(codepoints.count - codepointStart)
            unichars.removeLast(unichars.count - codepointStart)
            start = max(i + 1, j)
            return nil
        }

        // Length and font go into the hash too, as extra collision defence.
        hasher.combine(UInt64(j - i))
        hasher.combine(UInt64(font.slot))

        start = j
        return TextRun(
            hash: hasher.finalize(),
            offset: UInt16(i),
            count: UInt16(j - i),
            fontIndex: font,
            codepointStart: codepointStart,
            codepointCount: codepoints.count - codepointStart)
    }

    private func addCodepoint(_ hasher: inout RunHasher, _ cp: UInt32, _ cluster: UInt32) {
        hasher.combine(UInt64(cp))
        hasher.combine(UInt64(cluster))
        codepoints.append((cp: cp, cluster: cluster))

        // CoreText works in UTF-16. Non-BMP codepoints become a surrogate
        // pair, and we pad `codepoints` with a zero entry so its indices stay
        // aligned with the UTF-16 string CoreText reports back to us.
        if let scalar = Unicode.Scalar(cp) {
            if scalar.value > 0xFFFF {
                let v = scalar.value - 0x10000
                unichars.append(UniChar(0xD800 + (v >> 10)))
                unichars.append(UniChar(0xDC00 + (v & 0x3FF)))
                codepoints.append((cp: 0, cluster: cluster))
            } else {
                unichars.append(UniChar(scalar.value))
            }
        } else {
            unichars.append(UniChar(0xFFFD))
        }
    }

    /// Find a face that covers the cell's entire grapheme cluster.
    ///
    /// A single face has to render the whole cluster or the combining marks
    /// land in the wrong place, so we try the base codepoint's face and then
    /// each component's face until one covers everything.
    private func indexForCell(
        cell: RenderCell, graphemes: [UInt32], style: FontStyle,
        presentation: FontPresentation?
    ) -> FontIndex? {
        if !cell.hasText || cell.codepoint == 0 {
            return fontIndex(0x20, style, presentation)
        }

        guard let primary = fontIndex(cell.codepoint, style, presentation)
        else { return nil }

        // Common case: a single codepoint, so the primary answer stands.
        if cell.graphemeLen == 0 { return primary }

        let base = Int(cell.graphemeOffset)
        let extra = Array(graphemes[base..<(base + Int(cell.graphemeLen))])

        candidate: for i in 0...extra.count {
            let idx: FontIndex
            if i == 0 {
                idx = primary
            } else {
                let cp = extra[i - 1]
                // Joiners and variation selectors aren't required to be in
                // the face; skip them as candidates.
                if cp == 0xFE0E || cp == 0xFE0F || cp == 0x200D { continue }
                // Components need not support the base presentation: emoji
                // fonts commonly have the base emoji in colour but not the
                // gender signs that combine with it.
                guard let c = fontIndex(cp, style, nil) else { return nil }
                idx = c
            }

            if !grid.hasCodepoint(idx, cell.codepoint, presentation) { continue }
            for cp in extra {
                if cp == 0xFE0E || cp == 0xFE0F || cp == 0x200D { continue }
                if !grid.hasCodepoint(idx, cp, nil) { continue candidate }
            }
            return idx
        }

        return nil
    }

    // MARK: - Shaping

    /// Shape a run, from cache when possible.
    ///
    /// Only valid immediately after the `runs` call that produced it: the
    /// codepoint buffers it reads are reused.
    func shape(_ run: TextRun) -> [ShapedCell] {
        if let hit = cache.get(run.hash) { return hit }
        let cells = shapeUncached(run)
        cache.put(run.hash, cells)
        return cells
    }

    private func shapeUncached(_ run: TextRun) -> [ShapedCell] {
        let start = run.codepointStart
        let end = start + run.codepointCount
        guard start >= 0, end <= codepoints.count, end <= unichars.count, start < end
        else { return [] }

        // Sprite glyphs aren't shaped: their codepoint *is* their index.
        if run.fontIndex.isSprite {
            cellBuf.removeAll(keepingCapacity: true)
            for entry in codepoints[start..<end] where entry.cp != 0 {
                cellBuf.append(
                    ShapedCell(x: UInt16(entry.cluster), glyphIndex: entry.cp))
            }
            return cellBuf
        }

        guard let attrs = attributes(for: run.fontIndex) else { return [] }

        // CFStringCreateWithCharacters copies, so pointing it straight at
        // our slice avoids a temporary array on every cache miss.
        let string = unichars.withUnsafeBufferPointer { buf in
            CFStringCreateWithCharacters(nil, buf.baseAddress! + start, end - start)!
        }
        let attrString = CFAttributedStringCreate(nil, string, attrs)!
        guard
            let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(
                attrString, typesetterOptions)
        else { return [] }
        let line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 0))

        cellBuf.removeAll(keepingCapacity: true)

        // Running x across the whole line, and the furthest cluster seen.
        var runOffsetX: Double = 0
        var runOffsetCluster: UInt32 = 0
        // Where the current cell started.
        var cellOffsetX: Double = 0
        var cellOffsetCluster: UInt32 = 0

        // CoreText can emit non-monotonic runs even with the embedding level
        // forced. If it does we have to sort afterwards.
        var nonLTR = false

        let ctRuns = CTLineGetGlyphRuns(line) as! [CTRun]
        for ctRun in ctRuns {
            let status = CTRunGetStatus(ctRun)
            if status.contains(.rightToLeft) || status.contains(.nonMonotonic) { nonLTR = true }

            let count = CTRunGetGlyphCount(ctRun)
            if count == 0 { continue }

            var glyphs = [CGGlyph](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            let all = CFRangeMake(0, count)
            CTRunGetGlyphs(ctRun, all, &glyphs)
            CTRunGetAdvances(ctRun, all, &advances)
            CTRunGetPositions(ctRun, all, &positions)
            CTRunGetStringIndices(ctRun, all, &indices)

            for k in 0..<count {
                // String indices are relative to the slice we handed
                // CoreText, so shift them back into the row buffer.
                let index = start + indices[k]
                guard index >= start, index < end else { continue }
                let cluster = codepoints[index].cluster

                if cellOffsetCluster != cluster {
                    // Reset to the grid at the start of a new cluster — but
                    // only when this glyph really is the start of one.
                    //
                    // If the first codepoint of a cluster produced no glyph
                    // of its own, it almost certainly combined with earlier
                    // codepoints into a ligature, and the glyphs that follow
                    // are marks positioned relative to that ligature. Snapping
                    // those back to the grid would scatter them.
                    let afterCurrentOrLaterCluster = cluster <= runOffsetCluster

                    var isFirstInCluster = true
                    var back = index
                    while back > start {
                        back -= 1
                        // Skip the padding entries for surrogate pairs.
                        if codepoints[back].cp == 0 { continue }
                        isFirstInCluster = codepoints[back].cluster != cluster
                        break
                    }

                    if isFirstInCluster && !afterCurrentOrLaterCluster {
                        cellOffsetCluster = cluster
                        cellOffsetX = runOffsetX
                    }
                }

                cellBuf.append(
                    ShapedCell(
                        x: UInt16(cellOffsetCluster),
                        xOffset: Int16(clamping: Int((positions[k].x - cellOffsetX).rounded())),
                        yOffset: Int16(clamping: Int(positions[k].y.rounded())),
                        glyphIndex: UInt32(glyphs[k])))

                // Advances apply to the *next* glyph.
                runOffsetX += Double(advances[k].width)
                runOffsetCluster = max(runOffsetCluster, cluster)
            }
        }

        if nonLTR {
            // Exceptionally rare, and only for scripts CoreText reorders
            // despite the forced embedding level. The renderer relies on x
            // increasing monotonically.
            cellBuf.sort { $0.x < $1.x }
        }

        return cellBuf
    }

    /// The CFAttributedString attributes for a face: the font itself, plus
    /// the feature settings that make a terminal a terminal.
    private func attributes(for index: FontIndex) -> CFDictionary? {
        if let cached = attrCache[index.slot] { return cached }
        guard let face = grid.lock.withRead({ grid.face(index) }) else { return nil }

        let dict: [CFString: Any] = [
            kCTFontAttributeName: face.font,
            // Kerning must be off: every cell is exactly one advance wide
            // and kerning would slide glyphs off their columns.
            kCTKernAttributeName: 0 as CFNumber,
        ]
        let cf = dict as CFDictionary
        attrCache[index.slot] = cf
        return cf
    }
}

/// FNV-1a style mixing, matching the role Wyhash plays in libghostty's run
/// iterator: cheap, and only ever compared against itself.
private struct RunHasher {
    private var state: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ value: UInt64) {
        state ^= value
        state = state &* 0x0000_0100_0000_01B3
        // Extra avalanche, since our inputs are small integers that would
        // otherwise leave the high bits sparse.
        state ^= state >> 29
    }

    func finalize() -> UInt64 {
        var h = state
        h ^= h >> 33
        h = h &* 0xff51_afd7_ed55_8ccd
        h ^= h >> 33
        return h
    }
}
