//  ThemeRenderTests.swift
//  The colours a theme sets, checked where they end up: in pixels.
//
//  Only the ones the *renderer* resolves. `background`, `foreground`,
//  `cursor-color` and `palette` go into libghostty and come back out through
//  the snapshot, which `TerminalColorsTests` covers; what is left is the
//  handful of values a cell has to be present to resolve —
//  `selection-background = cell-foreground` and its three siblings, which are
//  a different colour on every cell they cover.
//
//  Backgrounds rather than glyphs throughout: a filled cell is a flat colour
//  that can be compared against an expected one exactly, where a glyph is
//  antialiased and only ever "mostly" a colour.

import XCTest

final class ThemeRenderTests: XCTestCase {
    private let cellFg = PackedRGB(r: 0xE0, g: 0x40, b: 0x40)
    private let cellBg = PackedRGB(r: 0x20, g: 0x30, b: 0xA0)

    /// One row of blanks, with cell 1 carrying its own foreground and
    /// background and the whole row selected.
    private func harness(
        inverse: Bool = false,
        configure: @escaping (inout RendererConfig) -> Void
    ) throws -> RenderHarness {
        let h = try RenderHarness(columns: 4, rows: 1, configure: configure)
        h.source.write(" ", row: 0, column: 1, flags: inverse ? [.inverse] : [])
        h.source.snapshot.rowData[0].cells[1].fg = cellFg
        h.source.snapshot.rowData[0].cells[1].bg = cellBg
        h.source.snapshot.rowData[0].cells[1].hasStyling = true
        h.source.snapshot.rowData[0].selection = (start: 0, end: 3)
        return h
    }

    private func assertCell(
        _ h: RenderHarness, _ image: RenderedImage, column: Int, is color: PackedRGB,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let cell = h.cellRect(column: column, row: 0)
        assertColor(
            image.pixel(x: cell.x + 1, y: cell.y + 1), ColorMath.expected(color),
            tolerance: 2, file: file, line: line)
    }

    // MARK: - Selection

    /// The default, and what the app drew before any of this was
    /// configurable: the selection inverts the *terminal's* two colours, so
    /// every selected cell is the same pair whatever it contained.
    func testSelectionWithNoConfigurationInvertsTheTerminal() throws {
        let h = try harness { _ in }
        let image = try h.render()
        assertCell(h, image, column: 0, is: h.source.snapshot.foreground)
        assertCell(h, image, column: 1, is: h.source.snapshot.foreground)
    }

    func testSelectionTakesAFixedColour() throws {
        let green = PackedRGB(r: 0x20, g: 0xC0, b: 0x40)
        let h = try harness {
            $0.selectionBackground = .color(r: green.r, g: green.g, b: green.b)
        }
        let image = try h.render()
        assertCell(h, image, column: 0, is: green)
        assertCell(h, image, column: 1, is: green)
    }

    /// `cell-foreground` inverts against the *cell*, so a selection over
    /// syntax highlighting keeps each token's own colour instead of
    /// flattening the lot to one pair.
    func testSelectionCellForegroundIsTheCellsOwnForeground() throws {
        let h = try harness { $0.selectionBackground = .cellForeground }
        let image = try h.render()
        assertCell(h, image, column: 1, is: cellFg)
        // A cell with no foreground of its own falls back to the terminal's.
        assertCell(h, image, column: 0, is: h.source.snapshot.foreground)
    }

    func testSelectionCellBackgroundIsTheCellsOwnBackground() throws {
        let h = try harness { $0.selectionBackground = .cellBackground }
        let image = try h.render()
        assertCell(h, image, column: 1, is: cellBg)
        // And with no background of its own, the terminal's — which is what
        // makes this spelling read as "leave the background alone".
        assertCell(h, image, column: 0, is: h.source.snapshot.background)
    }

    /// On a cell drawn in reverse video the two swap, because the colour you
    /// can *see* as its foreground is the one it stores as its background.
    /// libghostty's renderer makes the same swap.
    func testCellRelativeSelectionFollowsReverseVideo() throws {
        let h = try harness(inverse: true) { $0.selectionBackground = .cellForeground }
        assertCell(h, try h.render(), column: 1, is: cellBg)

        let g = try harness(inverse: true) { $0.selectionBackground = .cellBackground }
        assertCell(g, try g.render(), column: 1, is: cellFg)
    }

    // MARK: - The cursor

    /// A block cursor knocks the character out in the background colour
    /// unless `cursor-text` says otherwise. The cursor's own colour is the
    /// cell's foreground here, so the two are distinguishable.
    func testCursorTextTakesACellRelativeColour() throws {
        for (config, expected) in [
            (RenderColor.cellForeground, cellFg),
            (RenderColor.cellBackground, cellBg),
        ] {
            let h = try RenderHarness(columns: 4, rows: 1) { $0.cursorText = config }
            h.source.write("M", row: 0, column: 1)
            h.source.snapshot.rowData[0].cells[1].fg = cellFg
            h.source.snapshot.rowData[0].cells[1].bg = cellBg
            h.source.snapshot.rowData[0].cells[1].hasStyling = true
            h.source.snapshot.cursor.hasViewport = true
            h.source.snapshot.cursor.visible = true
            h.source.snapshot.cursor.style = .block
            h.source.snapshot.cursor.x = 1

            let image = try h.render()
            // The glyph is antialiased, so this asks whether *any* pixel in
            // the cell came out the expected colour rather than whether the
            // whole cell did.
            let cell = h.cellRect(column: 1, row: 0)
            let matching =
                cell.w * cell.h
                - image.countDiffering(
                    from: ColorMath.expected(expected),
                    x: cell.x, y: cell.y, w: cell.w, h: cell.h)
            XCTAssertGreaterThan(matching, 0, "no pixel of the glyph was \(expected)")
        }
    }
}
