//  RenderHarness.swift
//  Drives the renderer end to end, headlessly.
//
//  The renderer takes a `TerminalSnapshot` and produces pixels in an
//  IOSurface. Neither end needs a terminal, a PTY or a window, so these tests
//  build a screen by hand, render it, and read the result back — which is the
//  only way to check things like "does the cursor land on the right cell" or
//  "does a box drawing character reach both edges" without eyeballing a
//  screenshot.

import CoreGraphics
import Foundation
import IOSurface
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers
import XCTest

/// A snapshot the test controls directly.
final class FakeSource: TerminalRenderSource {
    let snapshot: TerminalSnapshot
    var dirty = true

    init(columns: Int, rows: Int) {
        snapshot = TerminalSnapshot()
        snapshot.resize(columns: columns, rows: rows)
        snapshot.dirty = .full
        snapshot.background = PackedRGB(r: 0x0C, g: 0x1F, b: 0x2F)
        snapshot.foreground = PackedRGB(r: 0xC8, g: 0xD6, b: 0xE0)
    }

    var isDirty: Bool { dirty }

    /// Copy the test's screen into the renderer's snapshot, refreshing only
    /// the rows a real engine would — so the dirty-tracking path is the one
    /// under test, not a shortcut around it.
    func updateSnapshot(into out: TerminalSnapshot) -> Bool {
        out.resize(columns: snapshot.columns, rows: snapshot.rows)
        out.dirty = snapshot.dirty
        out.background = snapshot.background
        out.foreground = snapshot.foreground
        out.cursorColor = snapshot.cursorColor
        out.cursor = snapshot.cursor

        for y in 0..<snapshot.rows {
            let isDirty = snapshot.dirty == .full || snapshot.rowDirty[y]
            out.rowDirty[y] = isDirty
            if isDirty { out.rowData[y] = snapshot.rowData[y] }
        }

        dirty = false
        return true
    }

    /// Put a string into a row, one codepoint per cell.
    func write(_ text: String, row: Int, column: Int = 0, flags: CellFlags = []) {
        var x = column
        for scalar in text.unicodeScalars {
            guard x < snapshot.columns else { break }
            var cell = RenderCell()
            cell.codepoint = scalar.value
            cell.hasText = true
            cell.hasStyling = !flags.isEmpty
            cell.flags = flags
            snapshot.rowData[row].cells[x] = cell
            x += 1
        }
    }

    func setBackground(_ color: PackedRGB, row: Int, column: Int) {
        snapshot.rowData[row].cells[column].bg = color
        snapshot.rowData[row].cells[column].hasStyling = true
    }
}

/// Pixels read back out of the render target.
struct RenderedImage {
    let width: Int
    let height: Int
    /// BGRA, row-major.
    let pixels: [UInt8]

    func pixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    /// True if every pixel in the rect is identical to the first.
    func isUniform(x: Int, y: Int, w: Int, h: Int) -> Bool {
        let first = pixel(x: x, y: y)
        for yy in y..<(y + h) {
            for xx in x..<(x + w) where pixel(x: xx, y: yy) != first {
                return false
            }
        }
        return true
    }

    /// How many pixels in the rect differ from `color`.
    func countDiffering(
        from color: (b: UInt8, g: UInt8, r: UInt8, a: UInt8),
        x: Int, y: Int, w: Int, h: Int, tolerance: Int = 2
    ) -> Int {
        var n = 0
        for yy in y..<(y + h) {
            for xx in x..<(x + w) {
                let p = pixel(x: xx, y: yy)
                let d =
                    abs(Int(p.b) - Int(color.b)) + abs(Int(p.g) - Int(color.g))
                    + abs(Int(p.r) - Int(color.r))
                if d > tolerance { n += 1 }
            }
        }
        return n
    }
}

/// Owns a renderer and its layer for the duration of a test.
final class RenderHarness {
    let context: MetalContext
    let grid: FontGrid
    let layer: CALayer
    let renderer: TerminalRenderer
    private let renderSource: TerminalRenderSource

    /// The scripted source, for tests that build a screen by hand.
    var source: FakeSource { renderSource as! FakeSource }

    let cellWidth: Int
    let cellHeight: Int

    /// Build a harness sized to hold exactly `columns` x `rows` cells with no
    /// padding, so grid coordinates map straight onto pixels.
    convenience init(
        columns: Int, rows: Int, pointSize: Double = 13, family: String? = "Menlo",
        configure: ((inout RendererConfig) -> Void)? = nil
    ) throws {
        try self.init(
            columns: columns, rows: rows, pointSize: pointSize, family: family,
            source: FakeSource(columns: columns, rows: rows), configure: configure)
    }

    /// `family` defaults to Menlo rather than to the app's own default so
    /// that a pixel assertion written against one face keeps measuring that
    /// face. Pass nil to render with the font we ship.
    init(
        columns: Int, rows: Int, pointSize: Double = 13, family: String? = "Menlo",
        source: TerminalRenderSource,
        configure: ((inout RendererConfig) -> Void)? = nil
    ) throws {
        context = try MetalContext.acquire()
        grid = FontGridSet.grid(family: family, pointSize: pointSize, scale: 2)

        cellWidth = Int(grid.metrics.cellWidth)
        cellHeight = Int(grid.metrics.cellHeight)

        renderSource = source
        layer = CALayer()

        var config = RendererConfig()
        // No padding: it would shift every cell and make the arithmetic in
        // the assertions harder to follow for no benefit.
        config.windowPaddingX = 0
        config.windowPaddingY = 0
        configure?(&config)
        renderer = TerminalRenderer(
            context: context, grid: grid, layer: layer, source: renderSource, config: config)
        // In the app this is `TerminalEngine.bind`, which hands the right to
        // draw to one renderer at a time. There is no engine here, so the
        // harness says it: without it every frame below would be skipped.
        renderer.setActive(true)

        let width = columns * cellWidth
        let height = rows * cellHeight
        layer.bounds = CGRect(x: 0, y: 0, width: Double(width) / 2, height: Double(height) / 2)
        layer.contentsScale = 2
        renderer.setScreenSize(width: width, height: height, scale: 2)
    }

    /// Render a frame and read the pixels back.
    func render() throws -> RenderedImage {
        (renderSource as? FakeSource)?.dirty = true
        renderer.updateFrame()
        renderer.drawFrame(sync: true)

        guard let contents = layer.contents else {
            throw XCTSkip("renderer produced no surface")
        }
        let surface = contents as! IOSurfaceRef

        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }

        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let src = base + y * bytesPerRow
            pixels.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress! + y * width * 4, src, width * 4)
            }
        }
        return RenderedImage(width: width, height: height, pixels: pixels)
    }

    /// The pixel rect covered by a grid cell.
    func cellRect(column: Int, row: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        (column * cellWidth, row * cellHeight, cellWidth, cellHeight)
    }
}

/// The colour pipeline, reimplemented independently of the shader.
///
/// The renderer is handed sRGB and writes into a Display P3 surface, so a
/// value does not come back out as it went in. Recomputing the expected
/// answer here is what makes the colour path testable rather than merely
/// self-consistent.
enum ColorMath {
    static func linearize(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func unlinearize(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055
    }

    /// sRGB (D50-adapted) to XYZ to Display P3, as the shader does it.
    static func srgbToDisplayP3(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        let srgbToXYZ: [[Double]] = [
            [0.4360747, 0.3850649, 0.1430804],
            [0.2225045, 0.7168786, 0.0606169],
            [0.0139322, 0.0971045, 0.7141733],
        ]
        let xyzToDisplayP3: [[Double]] = [
            [2.40414768, -0.99010704, -0.39759019],
            [-0.84239098, 1.79905954, 0.01597023],
            [0.04838763, -0.09752546, 1.27393636],
        ]
        func mul(_ m: [[Double]], _ v: (Double, Double, Double)) -> (Double, Double, Double) {
            (
                m[0][0] * v.0 + m[0][1] * v.1 + m[0][2] * v.2,
                m[1][0] * v.0 + m[1][1] * v.1 + m[1][2] * v.2,
                m[2][0] * v.0 + m[2][1] * v.1 + m[2][2] * v.2
            )
        }
        return mul(xyzToDisplayP3, mul(srgbToXYZ, c))
    }

    /// What an opaque sRGB colour should look like in the render target,
    /// under the default (non-linear) blending mode.
    static func expected(_ rgb: PackedRGB) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let lin = (
            linearize(Double(rgb.r) / 255),
            linearize(Double(rgb.g) / 255),
            linearize(Double(rgb.b) / 255)
        )
        let p3 = srgbToDisplayP3(lin)
        func encode(_ v: Double) -> UInt8 {
            UInt8(max(0, min(255, (unlinearize(max(0, min(1, v))) * 255).rounded())))
        }
        return (b: encode(p3.2), g: encode(p3.1), r: encode(p3.0), a: 255)
    }
}

extension RenderedImage {
    /// Write the frame out as a PNG.
    ///
    /// Opt-in via `ILLOGICAL_RENDER_DUMP=<dir>`, because the interesting
    /// rendering bugs are the ones you have to look at: a glyph half a pixel
    /// high, an underline one row too low, an atlas region off by one. A
    /// pixel assertion tells you something is wrong; the image tells you what.
    func dump(named name: String) {
        guard let dir = ProcessInfo.processInfo.environment["ILLOGICAL_RENDER_DUMP"] else {
            return
        }

        var pixels = self.pixels
        let provider = pixels.withUnsafeMutableBytes { raw -> CGDataProvider? in
            CGDataProvider(dataInfo: nil, data: raw.baseAddress!, size: raw.count) { _, _, _ in }
        }
        guard let provider,
            let space = CGColorSpace(name: CGColorSpace.displayP3),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                        | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { return }

        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(url.path)")
    }
}
