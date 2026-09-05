//  SpriteGeometryTests.swift
//  Exact placement checks for the glyphs we draw ourselves.
//
//  A box drawing character that is a pixel off looks fine on its own and
//  ruins every table it appears in, so "there is ink in the cell" is not a
//  useful assertion. These check *where* the ink is: which half, which
//  quadrant, whether it reaches the edge.

import XCTest

final class SpriteGeometryTests: XCTestCase {
    /// A one-cell harness and the ink map of its only cell.
    private struct Cell {
        let ink: [[Bool]]  // [y][x]
        let width: Int
        let height: Int

        func any(x: Range<Int>, y: Range<Int>) -> Bool {
            for yy in y where yy >= 0 && yy < height {
                for xx in x where xx >= 0 && xx < width {
                    if ink[yy][xx] { return true }
                }
            }
            return false
        }

        func all(x: Range<Int>, y: Range<Int>) -> Bool {
            for yy in y where yy >= 0 && yy < height {
                for xx in x where xx >= 0 && xx < width {
                    if !ink[yy][xx] { return false }
                }
            }
            return true
        }

        /// For failure messages: nothing beats seeing the glyph.
        var art: String {
            (0..<height).map { y in
                (0..<width).map { x in ink[y][x] ? "#" : "." }.joined()
            }.joined(separator: "\n")
        }
    }

    private func render(_ scalar: Unicode.Scalar, pointSize: Double = 26) throws -> Cell {
        let h = try RenderHarness(columns: 1, rows: 1, pointSize: pointSize)
        h.source.write(String(scalar), row: 0)
        let image = try h.render()
        let bg = ColorMath.expected(h.source.snapshot.background)

        var ink = [[Bool]](
            repeating: [Bool](repeating: false, count: image.width), count: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                ink[y][x] = image.countDiffering(from: bg, x: x, y: y, w: 1, h: 1) > 0
            }
        }
        return Cell(ink: ink, width: image.width, height: image.height)
    }

    /// ─ spans the full width, sits near the middle, and leaves the top and
    /// bottom clear.
    func testHorizontalLine() throws {
        let c = try render("\u{2500}")
        let mid = c.height / 2
        XCTAssertTrue(
            c.all(x: 0..<c.width, y: mid..<(mid + 1)) || c.all(x: 0..<c.width, y: (mid - 1)..<mid),
            "no full-width line at the vertical centre\n\(c.art)")
        XCTAssertFalse(c.any(x: 0..<c.width, y: 0..<(c.height / 4)), "ink near the top\n\(c.art)")
        XCTAssertFalse(
            c.any(x: 0..<c.width, y: (c.height * 3 / 4)..<c.height),
            "ink near the bottom\n\(c.art)")
    }

    /// │ spans the full height, sits near the middle, and leaves the sides
    /// clear.
    func testVerticalLine() throws {
        let c = try render("\u{2502}")
        let mid = c.width / 2
        XCTAssertTrue(
            c.all(x: mid..<(mid + 1), y: 0..<c.height)
                || c.all(x: (mid - 1)..<mid, y: 0..<c.height),
            "no full-height line at the horizontal centre\n\(c.art)")
        XCTAssertFalse(c.any(x: 0..<(c.width / 4), y: 0..<c.height), "ink at the left\n\(c.art)")
        XCTAssertFalse(
            c.any(x: (c.width * 3 / 4)..<c.width, y: 0..<c.height), "ink at the right\n\(c.art)")
    }

    /// ┌ occupies the bottom-right quadrant only: a line right from the
    /// centre and a line down from it.
    func testTopLeftCorner() throws {
        let c = try render("\u{250C}")
        let qw = c.width / 4
        let qh = c.height / 4

        XCTAssertFalse(
            c.any(x: 0..<qw, y: 0..<qh), "ink in the top-left quadrant\n\(c.art)")
        XCTAssertTrue(
            c.any(x: (c.width - qw)..<c.width, y: (c.height / 2 - 2)..<(c.height / 2 + 2)),
            "the arm does not reach the right edge\n\(c.art)")
        XCTAssertTrue(
            c.any(x: (c.width / 2 - 2)..<(c.width / 2 + 2), y: (c.height - qh)..<c.height),
            "the arm does not reach the bottom edge\n\(c.art)")
        XCTAssertFalse(
            c.any(x: 0..<qw, y: (c.height - qh)..<c.height),
            "ink in the bottom-left quadrant\n\(c.art)")
    }

    /// ┼ reaches all four edges.
    func testCross() throws {
        let c = try render("\u{253C}")
        let mx = (c.width / 2 - 2)..<(c.width / 2 + 2)
        let my = (c.height / 2 - 2)..<(c.height / 2 + 2)
        XCTAssertTrue(c.any(x: 0..<2, y: my), "no left arm\n\(c.art)")
        XCTAssertTrue(c.any(x: (c.width - 2)..<c.width, y: my), "no right arm\n\(c.art)")
        XCTAssertTrue(c.any(x: mx, y: 0..<2), "no up arm\n\(c.art)")
        XCTAssertTrue(c.any(x: mx, y: (c.height - 2)..<c.height), "no down arm\n\(c.art)")
    }

    /// █ fills the cell edge to edge.
    func testFullBlock() throws {
        let c = try render("\u{2588}")
        XCTAssertTrue(c.all(x: 0..<c.width, y: 0..<c.height), "FULL BLOCK has holes\n\(c.art)")
    }

    /// ▀ is the top half and nothing else.
    func testUpperHalfBlock() throws {
        let c = try render("\u{2580}")
        let half = c.height / 2
        XCTAssertTrue(c.all(x: 0..<c.width, y: 0..<(half - 1)), "top half not filled\n\(c.art)")
        XCTAssertFalse(
            c.any(x: 0..<c.width, y: (half + 1)..<c.height), "ink in the bottom half\n\(c.art)")
    }

    /// ▄ is the bottom half and nothing else.
    func testLowerHalfBlock() throws {
        let c = try render("\u{2584}")
        let half = c.height / 2
        XCTAssertFalse(
            c.any(x: 0..<c.width, y: 0..<(half - 1)), "ink in the top half\n\(c.art)")
        XCTAssertTrue(
            c.all(x: 0..<c.width, y: (half + 1)..<c.height), "bottom half not filled\n\(c.art)")
    }

    /// ▌ is the left half and nothing else.
    func testLeftHalfBlock() throws {
        let c = try render("\u{258C}")
        let half = c.width / 2
        XCTAssertTrue(c.all(x: 0..<(half - 1), y: 0..<c.height), "left half not filled\n\(c.art)")
        XCTAssertFalse(
            c.any(x: (half + 1)..<c.width, y: 0..<c.height), "ink in the right half\n\(c.art)")
    }

    /// The three shade blocks must be distinguishable from each other and
    /// from the background.
    func testShadeBlocksDiffer() throws {
        let h = try RenderHarness(columns: 3, rows: 1, pointSize: 26)
        h.source.write("\u{2591}\u{2592}\u{2593}", row: 0)
        let image = try h.render()

        var levels: [Int] = []
        for column in 0..<3 {
            let r = h.cellRect(column: column, row: 0)
            let p = image.pixel(x: r.x + r.w / 2, y: r.y + r.h / 2)
            levels.append(Int(p.r) + Int(p.g) + Int(p.b))
        }
        let bgPixel = ColorMath.expected(h.source.snapshot.background)
        let bgLevel = Int(bgPixel.r) + Int(bgPixel.g) + Int(bgPixel.b)

        XCTAssertGreaterThan(levels[0], bgLevel, "light shade is invisible")
        XCTAssertGreaterThan(levels[1], levels[0], "medium shade is not darker than light")
        XCTAssertGreaterThan(levels[2], levels[1], "dark shade is not darker than medium")
    }

    /// ╭ is a rounded version of ┌, so it lives in the same quadrant.
    func testRoundedCorner() throws {
        let c = try render("\u{256D}")
        let qw = c.width / 4
        let qh = c.height / 4
        XCTAssertFalse(c.any(x: 0..<qw, y: 0..<qh), "ink in the top-left quadrant\n\(c.art)")
        XCTAssertTrue(
            c.any(x: (c.width - qw)..<c.width, y: (c.height / 2 - 3)..<(c.height / 2 + 3)),
            "the arm does not reach the right edge\n\(c.art)")
        XCTAssertTrue(
            c.any(x: (c.width / 2 - 3)..<(c.width / 2 + 3), y: (c.height - qh)..<c.height),
            "the arm does not reach the bottom edge\n\(c.art)")
    }

    /// A filled powerline separator reaches the left edge and tapers to a
    /// point at the right.
    func testPowerlineRightTriangle() throws {
        let c = try render("\u{E0B0}")
        XCTAssertTrue(c.any(x: 0..<2, y: 0..<2), "no ink at the top-left\n\(c.art)")
        XCTAssertTrue(
            c.any(x: 0..<2, y: (c.height - 2)..<c.height), "no ink at the bottom-left\n\(c.art)")
        XCTAssertTrue(
            c.any(x: (c.width - 2)..<c.width, y: (c.height / 2 - 2)..<(c.height / 2 + 2)),
            "the point does not reach the right edge\n\(c.art)")
        XCTAssertFalse(
            c.any(x: (c.width - 2)..<c.width, y: 0..<2), "ink at the top-right\n\(c.art)")
    }
}
