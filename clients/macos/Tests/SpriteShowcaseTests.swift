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
