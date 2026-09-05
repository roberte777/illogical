//  MetalContext.swift
//  Device, shader library and pipelines, shared by every surface.
//
//  Mirrors what libghostty's `src/renderer/Metal.zig` and
//  `metal/shaders.zig` set up, with one difference: everything here is
//  process-wide. Compiling the library and building pipeline states are both
//  slow the first time and free afterwards, and a window with four splits
//  should pay once, not four times.

import Metal
import QuartzCore

/// The colour pipeline the renderer runs in.
///
/// `native` is what Ghostty defaults to on macOS: blend in the display's own
/// gamma-encoded space, which is what Terminal and TextEdit do, so text
/// weight matches the rest of the system. The linear modes are more
/// physically correct but make text look thin, which is why `linearCorrected`
/// exists to claw the weight back.
enum AlphaBlending {
    case native
    case linear
    case linearCorrected

    var isLinear: Bool {
        switch self {
        case .native: return false
        case .linear, .linearCorrected: return true
        }
    }

    /// An `*_srgb` format makes Metal gamma-encode *after* blending, which is
    /// what makes the blend linear.
    var pixelFormat: MTLPixelFormat {
        isLinear ? .bgra8Unorm_srgb : .bgra8Unorm
    }
}

enum MetalContextError: Error {
    case noDevice
    case noLibrary(String)
    case noFunction(String)
}

final class MetalContext: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    let blending: AlphaBlending

    /// Largest texture this device can make. Our render target is clamped to
    /// it, since a very large window on a weak GPU would otherwise fail.
    let maxTextureSize: Int

    let bgColorPipeline: MTLRenderPipelineState
    let cellBgPipeline: MTLRenderPipelineState
    let cellTextPipeline: MTLRenderPipelineState

    // Guarded by `sharedLock`.
    nonisolated(unsafe) private static var shared: MetalContext?
    private static let sharedLock = NSLock()

    /// The process-wide context, created on first use.
    static func acquire(blending: AlphaBlending = .native) throws -> MetalContext {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let shared, shared.blending == blending { return shared }
        let ctx = try MetalContext(blending: blending)
        shared = ctx
        return ctx
    }

    private init(blending: AlphaBlending) throws {
        guard let device = Self.chooseDevice() else { throw MetalContextError.noDevice }
        self.device = device
        self.blending = blending

        guard let queue = device.makeCommandQueue() else {
            throw MetalContextError.noDevice
        }
        self.commandQueue = queue

        // Look in the bundle this class came from before falling back to
        // the main bundle: under `xcodebuild test` the main bundle is the
        // test runner, which has no metallib of ours.
        let ownBundle = Bundle(for: MetalContext.self)
        let library =
            (try? device.makeDefaultLibrary(bundle: ownBundle))
            ?? device.makeDefaultLibrary()
        guard let library else {
            throw MetalContextError.noLibrary("default.metallib missing from the bundle")
        }
        self.library = library

        maxTextureSize = Self.queryMaxTextureSize(device)

        let format = blending.pixelFormat

        bgColorPipeline = try Self.pipeline(
            device: device, library: library,
            vertex: "full_screen_vertex", fragment: "bg_color_fragment",
            format: format, blending: false, vertexDescriptor: nil)

        cellBgPipeline = try Self.pipeline(
            device: device, library: library,
            vertex: "full_screen_vertex", fragment: "cell_bg_fragment",
            format: format, blending: true, vertexDescriptor: nil)

        cellTextPipeline = try Self.pipeline(
            device: device, library: library,
            vertex: "cell_text_vertex", fragment: "cell_text_fragment",
            format: format, blending: true,
            vertexDescriptor: Self.cellTextVertexDescriptor())
    }

    /// Prefer a GPU attached to a display, and among those prefer an
    /// integrated or removable one: integrated is better for battery and
    /// thermals, and if an eGPU is plugged in the user probably wants it.
    private static func chooseDevice() -> MTLDevice? {
        var chosen: MTLDevice? = nil
        for device in MTLCopyAllDevices() {
            if device.isHeadless { continue }
            chosen = device
            if device.isRemovable || device.isLowPower { break }
        }
        return chosen ?? MTLCreateSystemDefaultDevice()
    }

    /// https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
    private static func queryMaxTextureSize(_ device: MTLDevice) -> Int {
        if device.supportsFamily(.apple3) { return 16384 }
        return 8192
    }

    /// The instance layout for the cell text shader. Offsets must match
    /// `IllogicalCellText` in ShaderTypes.h; `RendererLayoutTests` asserts
    /// that they do.
    private static func cellTextVertexDescriptor() -> MTLVertexDescriptor {
        let d = MTLVertexDescriptor()
        let attrs: [(Int, MTLVertexFormat, Int)] = [
            (0, .uint2, 0),  // glyph_pos
            (1, .uint2, 8),  // glyph_size
            (2, .short2, 16),  // bearings
            (3, .ushort2, 20),  // grid_pos
            (4, .uchar4, 24),  // color
            (5, .uchar, 28),  // atlas
            (6, .uchar, 29),  // bools
        ]
        for (index, format, offset) in attrs {
            d.attributes[index].format = format
            d.attributes[index].offset = offset
            d.attributes[index].bufferIndex = Int(ILLO_BUFFER_VERTEX.rawValue)
        }
        let layout = d.layouts[Int(ILLO_BUFFER_VERTEX.rawValue)]!
        layout.stride = MemoryLayout<IllogicalCellText>.stride
        // One set of attributes per instance, not per vertex: the four
        // vertices of the quad come from the vertex id alone.
        layout.stepFunction = .perInstance
        layout.stepRate = 1
        return d
    }

    private static func pipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String,
        format: MTLPixelFormat,
        blending: Bool,
        vertexDescriptor: MTLVertexDescriptor?
    ) throws -> MTLRenderPipelineState {
        guard let vfn = library.makeFunction(name: vertex) else {
            throw MetalContextError.noFunction(vertex)
        }
        guard let ffn = library.makeFunction(name: fragment) else {
            throw MetalContextError.noFunction(fragment)
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.vertexDescriptor = vertexDescriptor

        let attachment = desc.colorAttachments[0]!
        attachment.pixelFormat = format
        attachment.isBlendingEnabled = blending
        if blending {
            // Premultiplied alpha throughout: the shaders premultiply as
            // part of loading a colour, so source-over is a plain add.
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        return try device.makeRenderPipelineState(descriptor: desc)
    }
}
