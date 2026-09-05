//  FrameState.swift
//  Per-frame GPU resources, and the render target they draw into.
//
//  Ported from the `SwapChain` / `FrameState` types in libghostty's
//  `src/renderer/generic.zig` and `metal/Target.zig`.
//
//  Everything the CPU writes while the GPU might still be reading the
//  previous frame has to be duplicated, or we get tearing and races. Three
//  copies lets the CPU build frame N+1 while the GPU draws N and the display
//  scans out N-1, which is what keeps the pipeline full.
//
//  The target is an IOSurface-backed texture rather than a CAMetalDrawable.
//  `nextDrawable` blocks on the display, so a renderer that wants to run
//  ahead can't; handing a CALayer an IOSurface decouples us from that
//  entirely and behaves far better during a live resize.

import IOSurface
import Metal
import QuartzCore

/// A GPU buffer that grows as needed and is written directly by the CPU.
///
/// `storageModeShared` on Apple silicon means no copy: the pointer we memcpy
/// into is the memory the GPU reads.
final class GrowableBuffer<T> {
    private(set) var buffer: MTLBuffer
    private(set) var capacity: Int
    private let device: MTLDevice

    init(device: MTLDevice, capacity: Int) {
        self.device = device
        self.capacity = max(1, capacity)
        buffer = device.makeBuffer(
            length: self.capacity * MemoryLayout<T>.stride,
            options: .storageModeShared)!
    }

    private func reserve(_ count: Int) {
        guard count > capacity else { return }
        // Double what we need, so a steadily growing screen doesn't
        // reallocate on every frame.
        capacity = count * 2
        buffer = device.makeBuffer(
            length: capacity * MemoryLayout<T>.stride,
            options: .storageModeShared)!
    }

    /// Replace the buffer contents with `values`.
    func sync(_ values: [T]) {
        reserve(values.count)
        guard !values.isEmpty else { return }
        values.withUnsafeBytes { src in
            buffer.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
    }

    /// Replace the contents with the concatenation of several arrays, which
    /// is how the per-row foreground lists reach the GPU as one buffer.
    /// Returns the total element count.
    @discardableResult
    func sync(concatenating lists: [ContiguousArray<T>]) -> Int {
        var total = 0
        for list in lists { total += list.count }
        reserve(total)
        guard total > 0 else { return 0 }

        var offset = 0
        let base = buffer.contents()
        for list in lists where !list.isEmpty {
            list.withUnsafeBytes { src in
                base.advanced(by: offset).copyMemory(
                    from: src.baseAddress!, byteCount: src.count)
                offset += src.count
            }
        }
        return total
    }
}

/// An IOSurface plus the Metal texture that renders into it.
final class RenderTarget {
    let surface: IOSurfaceRef
    let texture: MTLTexture
    let width: Int
    let height: Int

    init?(device: MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height

        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: Int(0x4247_5241),  // 'BGRA'
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else { return nil }
        self.surface = surface

        // Tag the surface as Display P3 so the compositor doesn't reinterpret
        // it. We render in P3 to get Apple-style blending: the system's own
        // apps composite text in the display's space, and matching that is
        // what keeps our text from looking subtly different from theirs.
        if let space = CGColorSpace(name: CGColorSpace.displayP3),
            let plist = space.copyPropertyList()
        {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, plist)
        }

        let desc = MTLTextureDescriptor()
        desc.width = width
        desc.height = height
        desc.pixelFormat = pixelFormat
        desc.usage = .renderTarget
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0)
        else { return nil }
        self.texture = texture
    }
}

/// One slot in the swap chain.
final class FrameState {
    let uniforms: GrowableBuffer<IllogicalUniforms>
    let cells: GrowableBuffer<IllogicalCellText>
    let cellsBg: GrowableBuffer<IllogicalCellBg>

    var grayscale: MTLTexture
    /// The atlas `modified` counter this texture was last uploaded from, so
    /// a frame that adds no glyphs uploads nothing.
    var grayscaleModified: UInt64 = 0
    var color: MTLTexture
    var colorModified: UInt64 = 0

    var target: RenderTarget?

    private let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
        uniforms = GrowableBuffer(device: device, capacity: 1)
        // Start the cell buffers at one element. They are inevitably too
        // small and get resized on the first frame; guessing a size would
        // just be wrong in a different way.
        cells = GrowableBuffer(device: device, capacity: 1)
        cellsBg = GrowableBuffer(device: device, capacity: 1)
        grayscale = Self.makeAtlasTexture(device: device, size: 1, format: .r8Unorm)
        color = Self.makeAtlasTexture(device: device, size: 1, format: .bgra8Unorm_srgb)
    }

    static func makeAtlasTexture(
        device: MTLDevice, size: Int, format: MTLPixelFormat
    )
        -> MTLTexture
    {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: max(1, size), height: max(1, size),
            mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        // The CPU writes this and never reads it back.
        desc.cpuCacheMode = .writeCombined
        return device.makeTexture(descriptor: desc)!
    }

    /// Push atlas bytes to a texture, recreating it if the atlas has grown.
    func syncAtlas(_ atlas: Atlas, texture: inout MTLTexture, format: MTLPixelFormat) {
        let size = Int(atlas.size)
        if texture.width != size {
            texture = Self.makeAtlasTexture(device: device, size: size, format: format)
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: atlas.data,
            bytesPerRow: size * atlas.format.depth)
    }

    func resize(width: Int, height: Int, pixelFormat: MTLPixelFormat) {
        target = RenderTarget(
            device: device, width: width, height: height, pixelFormat: pixelFormat)
    }
}
