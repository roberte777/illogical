//  SpriteShowcaseTests.swift
//  The glyphs we draw ourselves, rendered large enough to inspect.
//
//  Box drawing, blocks and powerline separators are the sprites whose whole
//  job is to meet their neighbours exactly, so the failure mode is a seam a
//  pixel wide. Rendering them at a large cell size and dumping the frame is
//  the only practical way to check that by eye; the assertions below cover
//  the cases that can be stated numerically.

import XCTest

final class SpriteShowcaseTests: XCTestCase {
    func testSpriteSheet() throws {
        let h = try RenderHarness(columns: 34, rows: 12, pointSize: 26)
        let s = h.source

        // Every intersection style, light, heavy and double.
        s.write("─━│┃┌┏╔┐┓╗└┗╚┘┛╝├┣╠┤┫╣┬┳╦┴┻╩┼╋╬", row: 0, column: 1)
        // Dashes, arcs and diagonals.
        s.write("┄┅┆┇┈┉┊┋╌╍╎╏╭╮╰╯╱╲╳", row: 1, column: 1)
        // Mixed weights meeting, which is where the stop calculations matter.
        s.write("┍┎┑┒┕┖┙┚┝┞┟┡┢┥┦┧┩┪┭┮┯┰┱┲┵┶┷┸┹┺", row: 2, column: 1)

        // Blocks: eighths across and down, then the shades.
        s.write("▁▂▃▄▅▆▇█▏▎▍▌▋▊▉█ ░▒▓ ▖▗▘▙▚▛▜▝▞▟", row: 4, column: 1)

        // A run of full blocks must come out as one unbroken bar.
        s.write("████████", row: 5, column: 1)
        // As must a run of horizontal lines.
        s.write("────────", row: 6, column: 1)
        // And a column of verticals, checked in the assertions below.
        for row in 7..<10 { s.write("│", row: row, column: 1) }

        // Braille, powerline, corner triangles.
        s.write("⠁⠂⠄⡀⢀⠈⠐⠠⣿⠿⡇⢸⣤⣶", row: 7, column: 3)
        s.write(
            "\u{E0B0}\u{E0B1}\u{E0B2}\u{E0B3}\u{E0B4}\u{E0B5}\u{E0B6}\u{E0B7}",
            row: 8, column: 3)
        s.write(
            "\u{E0B8}\u{E0B9}\u{E0BA}\u{E0BB}\u{E0BC}\u{E0BD}\u{E0BE}\u{E0BF}"
                + "\u{E0D2}\u{E0D4}", row: 9, column: 3)
        s.write("◢◣◤◥◸◹◺◿", row: 10, column: 3)

        // Cursors and underline styles.
        var bar = RenderCell()
        bar.codepoint = UInt32(UInt8(ascii: "x"))
        bar.hasText = true
        bar.hasStyling = true
        for (i, style) in ([.single, .double, .curly, .dotted, .dashed] as [CellUnderline])
            .enumerated()
        {
            bar.underline = style
            for dx in 0..<3 {
                s.snapshot.rowData[11].cells[1 + i * 4 + dx] = bar
            }
        }

        let image = try h.render()
        image.dump(named: "sprites")

        let bg = ColorMath.expected(s.snapshot.background)

        // A run of full blocks is one solid bar with no seams: every pixel
        // across all eight cells is ink.
        let blockRow = h.cellRect(column: 1, row: 5)
        let blockSpan = h.cellWidth * 8
        for y in blockRow.y..<(blockRow.y + blockRow.h) {
            XCTAssertEqual(
                image.countDiffering(from: bg, x: blockRow.x, y: y, w: blockSpan, h: 1),
                blockSpan,
                "FULL BLOCK run has a seam on pixel row \(y - blockRow.y)")
        }

        // A column of vertical lines is unbroken down the rows it spans.
        let vRect = h.cellRect(column: 1, row: 7)
        var inkRows = 0
        for y in vRect.y..<(vRect.y + h.cellHeight * 3)
        where image.countDiffering(from: bg, x: vRect.x, y: y, w: h.cellWidth, h: 1) > 0 {
            inkRows += 1
        }
        XCTAssertEqual(
            inkRows, h.cellHeight * 3, "vertical line run has a gap between rows")
    }
}

extension SpriteShowcaseTests {
    /// The blocks added since the original port: legacy computing, its
    /// Unicode 16 supplement, and branch drawing.
    func testLegacyAndBranchSheet() throws {
        let h = try RenderHarness(columns: 34, rows: 12, pointSize: 26)
        let s = h.source

        // Sextants: a 2x3 grid, sixty-three of them.
        s.write(String(String.UnicodeScalarView((0x1FB00...0x1FB1F).map { .init($0)! })), row: 0)
        s.write(String(String.UnicodeScalarView((0x1FB20...0x1FB3B).map { .init($0)! })), row: 1)
        // Smooth mosaics: diagonal-edged shapes that tile into curves.
        s.write(String(String.UnicodeScalarView((0x1FB3C...0x1FB5D).map { .init($0)! })), row: 2)
        // Eighths, block combinations and shades.
        s.write(String(String.UnicodeScalarView((0x1FB70...0x1FB91).map { .init($0)! })), row: 3)
        // Corner diagonals and cell diagonals.
        s.write(String(String.UnicodeScalarView((0x1FBA0...0x1FBAE).map { .init($0)! })), row: 4)
        s.write(String(String.UnicodeScalarView((0x1FBD0...0x1FBDF).map { .init($0)! })), row: 5)
        // Circles and quarter blocks.
        s.write(String(String.UnicodeScalarView((0x1FBE0...0x1FBEF).map { .init($0)! })), row: 6)
        // Octants: a 2x4 grid.
        s.write(String(String.UnicodeScalarView((0x1CD00...0x1CD1F).map { .init($0)! })), row: 7)
        // Separated quadrants and sextants.
        s.write(String(String.UnicodeScalarView((0x1CC21...0x1CC2F).map { .init($0)! })), row: 8)
        s.write(String(String.UnicodeScalarView((0x1CE51...0x1CE70).map { .init($0)! })), row: 9)
        // Branch drawing: lines, arcs and nodes.
        s.write(String(String.UnicodeScalarView((0xF5D0...0xF5EF).map { .init($0)! })), row: 10)
        s.write(String(String.UnicodeScalarView((0xF5F0...0xF60D).map { .init($0)! })), row: 11)

        let image = try h.render()
        image.dump(named: "sprites-legacy")

        let bg = ColorMath.expected(s.snapshot.background)
        for row in 0..<12 {
            XCTAssertGreaterThan(
                image.countDiffering(
                    from: bg, x: 0, y: row * h.cellHeight, w: image.width, h: h.cellHeight),
                0, "row \(row) drew nothing")
        }
    }
}
