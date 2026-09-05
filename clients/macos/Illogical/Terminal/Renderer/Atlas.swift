//  Atlas.swift
//  A square texture atlas with skyline rectangle packing.
//
//  Ported from libghostty's `src/font/Atlas.zig`, which is itself based on
//  Jukka Jylänki's "A Thousand Ways to Pack the Bin" by way of freetype-gl.
//
//  The packing is a skyline: `nodes` is the upper contour of used space, kept
//  sorted by x. Reserving finds the node where the rect fits with the lowest
//  resulting top edge, which keeps the contour flat and the atlas dense.
//
//  Two deliberate limitations, both inherited and both fine here:
//  the atlas is always square, and written data must be tightly packed.

import Foundation

/// A rectangle within an atlas.
struct AtlasRegion: Equatable {
    var x: UInt32 = 0
    var y: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
}

enum AtlasError: Error {
    /// The region does not fit. Grow the atlas and try again.
    case full
}

/// A texture atlas. Not thread safe; callers serialize access.
final class Atlas {
    enum Format {
        /// 1 byte per pixel, an alpha mask.
        case grayscale
        /// 4 bytes per pixel, premultiplied BGRA.
        case bgra

        var depth: Int {
            switch self {
            case .grayscale: return 1
            case .bgra: return 4
            }
        }
    }

    /// A span of free space at a given height. The skyline contour.
    private struct Node {
        var x: UInt32
        var y: UInt32
        var width: UInt32
    }

    let format: Format

    /// Raw texture bytes, `size * size * depth`. Kept as a manually managed
    /// buffer rather than `[UInt8]`: it is uploaded to the GPU every time it
    /// changes and we never want a copy-on-write to sneak in.
    private(set) var data: UnsafeMutableRawPointer
    private(set) var size: UInt32

    private var nodes: ContiguousArray<Node> = []

    /// Bumped on every write. The renderer compares it against the value it
    /// last uploaded, so a frame that adds no new glyphs re-uploads nothing.
    private(set) var modified: UInt64 = 0
    /// Bumped on every resize, so the renderer knows to recreate the texture
    /// rather than replace a region of it.
    private(set) var resized: UInt64 = 0

    init(size: UInt32, format: Format) {
        self.format = format
        self.size = size
        let byteCount = Int(size) * Int(size) * format.depth
        self.data = .allocate(byteCount: byteCount, alignment: 64)
        self.data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        nodes.reserveCapacity(64)
        clear()
    }

    deinit {
        data.deallocate()
    }

    var byteCount: Int { Int(size) * Int(size) * format.depth }

    /// Reserve `width` x `height`. Does not grow the atlas; on `.full` the
    /// caller grows and retries.
    func reserve(width: UInt32, height: UInt32) throws -> AtlasRegion {
        var region = AtlasRegion(x: 0, y: 0, width: width, height: height)

        // Zero-sized reservations are legal and return immediately. Callers
        // rasterizing an empty glyph shouldn't need to special-case it, and a
        // zero-width node would corrupt the skyline.
        if width == 0 || height == 0 { return region }

        var bestHeight = UInt32.max
        var bestWidth = UInt32.max
        var chosen: Int? = nil

        for i in nodes.indices {
            guard let y = fit(at: i, width: width, height: height) else { continue }
            let node = nodes[i]
            if (y + height) < bestHeight
                || ((y + height) == bestHeight && node.width > 0 && node.width < bestWidth)
            {
                chosen = i
                bestWidth = node.width
                bestHeight = y + height
                region.x = node.x
                region.y = y
            }
        }

        guard let bestIdx = chosen else { throw AtlasError.full }

        nodes.insert(
            Node(x: region.x, y: region.y + height, width: width), at: bestIdx)

        // Trim any nodes the new one now overhangs, dropping those it covers
        // completely.
        var i = bestIdx + 1
        while i < nodes.count {
            let prev = nodes[i - 1]
            if nodes[i].x < (prev.x + prev.width) {
                let shrink = prev.x + prev.width - nodes[i].x
                nodes[i].x += shrink
                nodes[i].width = nodes[i].width > shrink ? nodes[i].width - shrink : 0
                if nodes[i].width == 0 {
                    nodes.remove(at: i)
                    continue
                }
            }
            break
        }

        merge()
        return region
    }

    /// The y at which a `width` x `height` rect can sit on the node at `idx`,
    /// or nil if it cannot fit there.
    private func fit(at idx: Int, width: UInt32, height: UInt32) -> UInt32? {
        let node = nodes[idx]
        if (node.x + width) > (size - 1) { return nil }

        var y = node.y
        var i = idx
        var widthLeft = width
        while widthLeft > 0 {
            // Walking off the end means the contour cannot span the width.
            guard i < nodes.count else { return nil }
            let n = nodes[i]
            if n.y > y { y = n.y }
            if (y + height) > (size - 1) { return nil }
            widthLeft = widthLeft > n.width ? widthLeft - n.width : 0
            i += 1
        }
        return y
    }

    /// Collapse adjacent nodes at the same height back into one span.
    private func merge() {
        guard nodes.count > 1 else { return }
        var i = 0
        while i < nodes.count - 1 {
            if nodes[i].y == nodes[i + 1].y {
                nodes[i].width += nodes[i + 1].width
                nodes.remove(at: i + 1)
                continue
            }
            i += 1
        }
    }

    /// Write tightly packed pixels into a reserved region.
    func set(_ region: AtlasRegion, _ source: UnsafeRawPointer) {
        guard region.width > 0, region.height > 0 else { return }
        precondition(region.x + region.width <= size - 1)
        precondition(region.y + region.height <= size - 1)

        let depth = format.depth
        let rowBytes = Int(region.width) * depth
        let dst = data.assumingMemoryBound(to: UInt8.self)
        let src = source.assumingMemoryBound(to: UInt8.self)
        for row in 0..<Int(region.height) {
            let texOffset = ((Int(region.y) + row) * Int(size) + Int(region.x)) * depth
            let dataOffset = row * rowBytes
            memcpy(dst + texOffset, src + dataOffset, rowBytes)
        }
        modified &+= 1
    }

    /// Write a sub-rectangle of a larger buffer into a reserved region.
    /// Used by the sprite rasterizer, which trims transparent margins off a
    /// padded canvas rather than reallocating it.
    func set(
        _ region: AtlasRegion,
        from source: UnsafeRawPointer,
        sourceWidth: UInt32,
        sourceX: UInt32,
        sourceY: UInt32
    ) {
        guard region.width > 0, region.height > 0 else { return }
        precondition(region.x + region.width <= size - 1)
        precondition(region.y + region.height <= size - 1)

        let depth = format.depth
        let rowBytes = Int(region.width) * depth
        let dst = data.assumingMemoryBound(to: UInt8.self)
        let src = source.assumingMemoryBound(to: UInt8.self)
        for row in 0..<Int(region.height) {
            let texOffset = ((Int(region.y) + row) * Int(size) + Int(region.x)) * depth
            let srcOffset = ((Int(sourceY) + row) * Int(sourceWidth) + Int(sourceX)) * depth
            memcpy(dst + texOffset, src + srcOffset, rowBytes)
        }
        modified &+= 1
    }

    /// Double the atlas, preserving everything already packed.
    func grow(to newSize: UInt32) {
        precondition(newSize >= size)
        if newSize == size { return }

        let depth = format.depth
        let newByteCount = Int(newSize) * Int(newSize) * depth
        let newData = UnsafeMutableRawPointer.allocate(
            byteCount: newByteCount, alignment: 64)
        newData.initializeMemory(as: UInt8.self, repeating: 0, count: newByteCount)

        let oldData = data
        let oldSize = size
        data = newData
        size = newSize

        // Copy the old contents back in. We skip the first and last border
        // rows so the copy is a plain row-by-row blit with no stride games.
        set(
            AtlasRegion(x: 0, y: 1, width: oldSize, height: oldSize - 2),
            oldData.advanced(by: Int(oldSize) * depth))
        oldData.deallocate()

        // The space we just gained on the right is one new free span.
        nodes.append(Node(x: oldSize - 1, y: 1, width: newSize - oldSize))

        modified &+= 1
        resized &+= 1
    }

    /// Reset to empty without giving back the allocation.
    func clear() {
        data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        nodes.removeAll(keepingCapacity: true)
        // A one pixel border all round stops a glyph bleeding into its
        // neighbour when the sampler lands on an edge.
        nodes.append(Node(x: 1, y: 1, width: size - 2))
        modified &+= 1
    }
}
