//  RenderShowcaseTests.swift
//  A representative screen, rendered and checked.
//
//  Everything a terminal actually puts on screen in one frame: styled text,
//  true colour, a table drawn with box characters, block shading, powerline
//  separators, braille, a wide character and a cursor. The assertions are
//  coarse — the point is that the whole pipeline runs over realistic content
//  without dropping anything — but with `ILLOGICAL_RENDER_DUMP` set it also
//  writes the frame out to look at.

import XCTest

final class RenderShowcaseTests: XCTestCase {
    func testShowcaseScreen() throws {
        let h = try RenderHarness(columns: 44, rows: 14)
        let s = h.source

        s.write("illogical — Metal renderer", row: 0, column: 1, flags: [.bold])

        s.write("regular  ", row: 2, column: 1)
        s.write("bold  ", row: 2, column: 10, flags: [.bold])
        s.write("italic  ", row: 2, column: 16, flags: [.italic])
        s.write("faint", row: 2, column: 24, flags: [.faint])

        // Underline styles, one per column group.
        let underlines: [CellUnderline] = [.single, .double, .curly, .dotted, .dashed]
        for (i, style) in underlines.enumerated() {
            for dx in 0..<7 {
                var cell = RenderCell()
                cell.codepoint = UInt32(UInt8(ascii: "a") + UInt8(i))
                cell.hasText = true
                cell.hasStyling = true
                cell.underline = style
                s.snapshot.rowData[3].cells[1 + i * 8 + dx] = cell
            }
        }

        // True colour, a gradient of cell backgrounds.
        for x in 0..<40 {
            let t = Double(x) / 39
            s.setBackground(
                PackedRGB(
                    r: UInt8(255 * t), g: UInt8(80 + 100 * (1 - t)), b: UInt8(255 * (1 - t))),
                row: 4, column: x + 1)
        }

        // A box-drawn table.
        s.write("┌────────────┬───────────┐", row: 6, column: 1)
        s.write("│ terminal   │ frames/s  │", row: 7, column: 1)
        s.write("├────────────┼───────────┤", row: 8, column: 1)
        s.write("│ illogical  │       120 │", row: 9, column: 1)
        s.write("└────────────┴───────────┘", row: 10, column: 1)

        // Rounded corners and heavy lines.
        s.write("╭──╮ ┏━━┓ ╔══╗", row: 6, column: 29)

        // Blocks, shades and braille.
        s.write("█▉▊▋▌▍▎▏ ░▒▓ ⠿⣿⡇⢸", row: 11, column: 1)

        // Powerline separators.
        s.write("\u{E0B0}\u{E0B1}\u{E0B2}\u{E0B3}\u{E0B4}\u{E0B6}", row: 12, column: 1)

        // A wide character, with its spacer tail as a real terminal would
        // have it.
        var wide = RenderCell()
        wide.codepoint = 0x6C34  // 水
        wide.hasText = true
        wide.wide = .wide
        s.snapshot.rowData[12].cells[10] = wide
        var tail = RenderCell()
        tail.wide = .spacerTail
        s.snapshot.rowData[12].cells[11] = tail

        // Inverse and strikethrough.
        s.write(" selected ", row: 13, column: 1, flags: [.inverse])
        s.write("struck", row: 13, column: 13, flags: [.strikethrough])

        s.snapshot.cursor = SnapshotCursor(
            hasViewport: true, x: 21, y: 13, wideTail: false, visible: true,
            blinking: false, passwordInput: false, style: .block)

        let image = try h.render()
        image.dump(named: "showcase")

        // Every row we drew into should have ink in it.
        let bg = ColorMath.expected(s.snapshot.background)
        for row in [0, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13] {
            let ink = image.countDiffering(
                from: bg, x: 0, y: row * h.cellHeight, w: image.width, h: h.cellHeight)
            XCTAssertGreaterThan(ink, 0, "row \(row) drew nothing")
        }

        // And the rows we left blank should be untouched.
        for row in [1, 5] {
            let ink = image.countDiffering(
                from: bg, x: 0, y: row * h.cellHeight, w: image.width, h: h.cellHeight)
            XCTAssertEqual(ink, 0, "row \(row) should be empty")
        }
    }
}
