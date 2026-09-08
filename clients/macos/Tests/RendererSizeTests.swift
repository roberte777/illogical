//  RendererSizeTests.swift
//  Where the grid sits inside a surface that is not a whole number of cells.
//
//  A surface is almost never an exact multiple of the cell size, and what is
//  done with the remainder decides whether a live resize is calm. Leaving it
//  at the right and bottom pins the origin: dragging an edge changes what is
//  *below* the last row, and every glyph on screen stays where it was.
//  Balancing it moves the origin instead — half a cell of drift, snapping back
//  on each row the grid gains — and the whole screen, scrollback included,
//  jitters under the pointer. Hence libghostty's default, and ours.

import XCTest

final class RendererSizeTests: XCTestCase {
    private let cell = CellSize(width: 16, height: 34)
    private let explicit = EdgePadding(top: 4, bottom: 4, right: 4, left: 4)

    private func size(width: UInt32, height: UInt32, mode: PaddingBalance) -> RendererSize {
        var size = RendererSize(
            screen: ScreenSize(width: width, height: height),
            cell: cell,
            padding: EdgePadding())
        size.balancePadding(explicit: explicit, mode: mode)
        return size
    }

    /// What the renderer is actually configured with, since every test below
    /// names its mode rather than reading one.
    func testTheDefaultIsNotToBalance() {
        XCTAssertEqual(RendererConfig().windowPaddingBalance, .none)
    }

    /// The origin holds across a drag long enough to gain rows and columns.
    ///
    /// Two full cells in each axis, a pixel at a time — every intermediate
    /// size a resize passes through, not just the ones that divide evenly.
    func testDefaultPaddingKeepsGridOriginStill() {
        for height in stride(from: UInt32(800), through: 800 + cell.height * 2, by: 1) {
            for width in stride(from: UInt32(1600), through: 1600 + cell.width * 2, by: 1) {
                let size = size(width: width, height: height, mode: .none)
                XCTAssertEqual(
                    size.padding.top, explicit.top,
                    "top padding moved at \(width)x\(height)")
                XCTAssertEqual(
                    size.padding.left, explicit.left,
                    "left padding moved at \(width)x\(height)")
            }
        }
    }

    /// The slack the origin no longer absorbs still has to be accounted for:
    /// it is what the renderer hands the shader as `grid_padding`, and it is
    /// the region nothing draws into. Measured the way the renderer measures
    /// it, off the whole screen rather than the terminal inside it.
    ///
    /// Under a cell in each axis, or the grid gave up a row it had room for.
    func testDefaultPaddingLeavesTheSlackAtTheBottomRight() {
        for height in stride(from: UInt32(800), through: 800 + cell.height, by: 1) {
            let size = size(width: 1607, height: height, mode: .none)
            let grid = size.grid
            let blank = size.screen.blankPadding(size.padding, grid: grid, cell: cell)

            XCTAssertEqual(blank.top, 0, "slack above the first row at height \(height)")
            XCTAssertEqual(blank.left, 0, "slack left of the first column at height \(height)")
            XCTAssertLessThan(
                blank.bottom, cell.height, "a whole row of slack at height \(height)")
            XCTAssertLessThan(
                blank.right, cell.width, "a whole column of slack at height \(height)")
            XCTAssertEqual(
                size.padding.top + UInt32(grid.rows) * cell.height + size.padding.bottom
                    + blank.bottom,
                height,
                "vertical slack unaccounted for at height \(height)")
            XCTAssertEqual(
                size.padding.left + UInt32(grid.columns) * cell.width + size.padding.right
                    + blank.right,
                size.screen.width,
                "horizontal slack unaccounted for at height \(height)")
        }
    }

    /// The same claim in pixels, through the renderer that draws them.
    ///
    /// Resize the surface by less than a row, in both directions — every
    /// intermediate size a drag passes through — and the frame above the slack
    /// has to come back byte for byte. The geometry tests above say the origin
    /// holds; this says the projection and the shader agree with them.
    func testTextDoesNotMoveAsTheSurfaceResizesWithinARow() throws {
        let harness = try RenderHarness(columns: 40, rows: 12) { config in
            config.windowPaddingX = 8
            config.windowPaddingY = 8
        }
        harness.source.write("the quick brown fox", row: 0)
        harness.source.write("jumps over the lazy dog", row: 5)
        harness.source.write("and lands on the last row", row: 11)

        // 8pt of padding at the harness's scale of 2, on all four sides.
        let padding = 16
        let width = 40 * harness.cellWidth + padding * 2
        let height = 12 * harness.cellHeight + padding * 2

        harness.renderer.setScreenSize(width: width, height: height, scale: 2)
        let before = try harness.render()

        // Up through a row's worth of slack and back down to where it started:
        // a drag does both, and a shrink hands the renderer a target smaller
        // than the one that frame slot last held.
        for extra in [1, 3, harness.cellHeight - 1, 3, 1, 0] {
            harness.renderer.setScreenSize(width: width, height: height + extra, scale: 2)
            let after = try harness.render()

            XCTAssertEqual(after.height, height + extra)
            let row = (0..<height).first { y in
                let start = y * width * 4
                let end = start + width * 4
                return !before.pixels[start..<end].elementsEqual(after.pixels[start..<end])
            }
            XCTAssertNil(row, "row \(row ?? -1) moved at \(extra)px of slack")
        }
    }

    /// The other half of the claim: balancing is what moved the grid. Pinned
    /// so that turning it back on is a decision rather than an accident.
    func testBalancedPaddingMovesTheGridOrigin() {
        var tops = Set<UInt32>()
        for height in stride(from: UInt32(800), through: 800 + cell.height, by: 1) {
            tops.insert(size(width: 1600, height: height, mode: .balanced).padding.top)
        }
        XCTAssertGreaterThan(
            tops.count, 1, "balanced padding is supposed to move the origin")
    }
}
