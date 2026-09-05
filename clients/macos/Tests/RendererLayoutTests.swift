//  RendererLayoutTests.swift
//  The Swift and MSL views of the shared structs must agree.
//
//  `Shaders.metal` declares its own `Uniforms` rather than including
//  ShaderTypes.h, so that the shader source stays self-contained. These
//  assertions are what stop the two definitions from drifting: a mismatch
//  would not fail to compile, it would render garbage.

import Metal
import XCTest
import simd

final class RendererLayoutTests: XCTestCase {
    /// Layout the MSL compiler computes for `struct Uniforms` in
    /// Shaders.metal, worked out from the MSL alignment rules:
    /// float4x4(64/16) float2(8/8) float2(8/8) ushort2(4/4) float4(16/16)
    /// uint8(1/1) float(4/4) ushort2(4/4) uchar4(4/4) uchar4(4/4) 4x bool.
    func testUniformsLayout() {
        XCTAssertEqual(MemoryLayout<IllogicalUniforms>.size, 144)
        XCTAssertEqual(MemoryLayout<IllogicalUniforms>.stride, 144)
        XCTAssertEqual(MemoryLayout<IllogicalUniforms>.alignment, 16)
    }

    /// The instance struct. Kept at 32 bytes deliberately: a full screen of
    /// underlined text is tens of thousands of these per frame.
    func testCellTextLayout() {
        XCTAssertEqual(MemoryLayout<IllogicalCellText>.size, 32)
        XCTAssertEqual(MemoryLayout<IllogicalCellText>.stride, 32)
        XCTAssertEqual(MemoryLayout<IllogicalCellText>.alignment, 8)
    }

    func testCellBgLayout() {
        XCTAssertEqual(MemoryLayout<IllogicalCellBg>.size, 4)
    }

    /// The vertex descriptor's offsets are hand-written in MetalContext, so
    /// check them against the struct they claim to describe.
    func testCellTextFieldOffsets() {
        XCTAssertEqual(MemoryLayout<IllogicalCellText>.offset(of: \.glyph_pos), 0)
        XCTAssertEqual(MemoryLayout<IllogicalCellText>.offset(of: \.glyph_size), 8)
        XCTAssertEqual(MemoryLayout<IllogicalCellText>.offset(of: \.bearings), 16)
        XCTAssertEqual(MemoryLayout<IllogicalCellText>.offset(of: \.grid_pos), 20)
        XCTAssertEqual(MemoryLayout<IllogicalCellText>.offset(of: \.color), 24)
        XCTAssertEqual(MemoryLayout<IllogicalCellText>.offset(of: \.atlas), 28)
        XCTAssertEqual(MemoryLayout<IllogicalCellText>.offset(of: \.bools), 29)
    }

    /// The shader library must load and expose every function the pipelines
    /// ask for.
    func testShaderLibraryLoads() throws {
        let context = try MetalContext.acquire()
        let names = Set(context.library.functionNames)
        for name in [
            "full_screen_vertex", "bg_color_fragment", "cell_bg_fragment",
            "cell_text_vertex", "cell_text_fragment",
        ] {
            XCTAssertTrue(names.contains(name), "missing shader function \(name)")
        }
    }
}
