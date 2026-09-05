//  AtlasTests.swift
//  The rectangle packer, which everything drawn depends on.
//
//  A packing bug shows up as one glyph wearing a slice of another, which is
//  hard to attribute and easy to miss. The invariants are simple enough to
//  state directly: regions never overlap, they stay inside the border, and
//  growing preserves what was already packed.

import XCTest

final class AtlasTests: XCTestCase {
    private func overlaps(_ a: AtlasRegion, _ b: AtlasRegion) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height
            && b.y < a.y + a.height
    }

    func testReservationsNeverOverlap() throws {
        let atlas = Atlas(size: 256, format: .grayscale)
        var regions: [AtlasRegion] = []

        // A mix of sizes, as a real glyph run would be.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let w = UInt32.random(in: 1...20, using: &rng)
            let h = UInt32.random(in: 1...30, using: &rng)
            guard let region = try? atlas.reserve(width: w, height: h) else { break }
            XCTAssertEqual(region.width, w)
            XCTAssertEqual(region.height, h)
            regions.append(region)
        }

        XCTAssertGreaterThan(regions.count, 50, "packed suspiciously few regions")
        for (i, a) in regions.enumerated() {
            // The one pixel border keeps sampling from bleeding between
            // neighbours, so nothing may touch the edges.
            XCTAssertGreaterThanOrEqual(a.x, 1)
            XCTAssertGreaterThanOrEqual(a.y, 1)
            XCTAssertLessThanOrEqual(a.x + a.width, atlas.size - 1)
            XCTAssertLessThanOrEqual(a.y + a.height, atlas.size - 1)
            for b in regions[(i + 1)...] {
                XCTAssertFalse(overlaps(a, b), "regions overlap: \(a) and \(b)")
            }
        }
    }

    func testZeroSizedReservationIsHarmless() throws {
        let atlas = Atlas(size: 64, format: .grayscale)
        let before = try atlas.reserve(width: 4, height: 4)
        _ = try atlas.reserve(width: 0, height: 5)
        _ = try atlas.reserve(width: 5, height: 0)
        // A zero-width node would corrupt the skyline; the next real
        // reservation should still behave.
        let after = try atlas.reserve(width: 4, height: 4)
        XCTAssertFalse(overlaps(before, after))
    }

    func testFullAtlasThrows() {
        let atlas = Atlas(size: 32, format: .grayscale)
        XCTAssertThrowsError(try atlas.reserve(width: 40, height: 4))
        XCTAssertThrowsError(try atlas.reserve(width: 4, height: 40))
    }

    func testWrittenDataLandsInTheRegion() throws {
        let atlas = Atlas(size: 64, format: .grayscale)
        let region = try atlas.reserve(width: 3, height: 2)
        let pixels: [UInt8] = [1, 2, 3, 4, 5, 6]
        pixels.withUnsafeBytes { atlas.set(region, $0.baseAddress!) }

        let data = atlas.data.assumingMemoryBound(to: UInt8.self)
        for row in 0..<2 {
            for col in 0..<3 {
                let offset = (Int(region.y) + row) * Int(atlas.size) + Int(region.x) + col
                XCTAssertEqual(data[offset], pixels[row * 3 + col])
            }
        }
    }

    /// Growing has to preserve everything already packed, or every glyph
    /// rasterized before the first resize would come back as garbage.
    func testGrowPreservesContents() throws {
        let atlas = Atlas(size: 64, format: .grayscale)
        var regions: [(AtlasRegion, UInt8)] = []
        for i in 0..<20 {
            let region = try atlas.reserve(width: 4, height: 4)
            let value = UInt8(i + 1)
            let pixels = [UInt8](repeating: value, count: 16)
            pixels.withUnsafeBytes { atlas.set(region, $0.baseAddress!) }
            regions.append((region, value))
        }

        let modifiedBefore = atlas.modified
        atlas.grow(to: 128)
        XCTAssertEqual(atlas.size, 128)
        XCTAssertGreaterThan(atlas.modified, modifiedBefore)
        XCTAssertGreaterThan(atlas.resized, 0)

        let data = atlas.data.assumingMemoryBound(to: UInt8.self)
        for (region, value) in regions {
            for row in 0..<Int(region.height) {
                for col in 0..<Int(region.width) {
                    let offset =
                        (Int(region.y) + row) * Int(atlas.size) + Int(region.x) + col
                    XCTAssertEqual(
                        data[offset], value, "lost data at \(region) after growing")
                }
            }
        }
    }

    /// After growing, the new space is usable and doesn't collide with the
    /// old contents.
    func testGrowMakesRoom() throws {
        let atlas = Atlas(size: 32, format: .grayscale)
        var regions: [AtlasRegion] = []
        while let region = try? atlas.reserve(width: 8, height: 8) {
            regions.append(region)
            if regions.count > 100 { break }
        }
        XCTAssertThrowsError(try atlas.reserve(width: 8, height: 8), "atlas should be full")

        atlas.grow(to: 64)
        let fresh = try atlas.reserve(width: 8, height: 8)
        for old in regions {
            XCTAssertFalse(overlaps(old, fresh), "new region overlaps an old one")
        }
    }

    func testColourAtlasIsFourBytesPerPixel() throws {
        let atlas = Atlas(size: 32, format: .bgra)
        XCTAssertEqual(atlas.format.depth, 4)
        XCTAssertEqual(atlas.byteCount, 32 * 32 * 4)

        let region = try atlas.reserve(width: 2, height: 1)
        let pixels: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        pixels.withUnsafeBytes { atlas.set(region, $0.baseAddress!) }
        let data = atlas.data.assumingMemoryBound(to: UInt8.self)
        let offset = (Int(region.y) * Int(atlas.size) + Int(region.x)) * 4
        for i in 0..<8 {
            XCTAssertEqual(data[offset + i], pixels[i])
        }
    }

    /// A glyph larger than the current atlas still gets rasterized: the font
    /// grid grows the atlas until it fits.
    func testGlyphLargerThanTheAtlasStillRenders() throws {
        // A big font against a small atlas forces at least one growth.
        let grid = FontGridSet.grid(family: "Menlo", pointSize: 96, scale: 2)
        let index = try XCTUnwrap(
            grid.index(codepoint: UInt32(UInt8(ascii: "W")), style: .regular, presentation: nil))
        let face = try XCTUnwrap(grid.lock.withRead { grid.face(index) })
        let glyphIndex = try XCTUnwrap(face.glyphIndex(UInt32(UInt8(ascii: "W"))))

        let render = try grid.renderGlyph(index, glyph: glyphIndex, options: .init())
        XCTAssertFalse(render.glyph.isEmpty)
        XCTAssertLessThanOrEqual(
            render.glyph.atlasX + render.glyph.width, grid.atlasGrayscale.size)
        XCTAssertLessThanOrEqual(
            render.glyph.atlasY + render.glyph.height, grid.atlasGrayscale.size)
    }
}
