//  RendererSize.swift
//  Screen, cell, grid and padding, and converting between them.
//
//  Ported from libghostty's `src/renderer/size.zig`. Everything here is in
//  device pixels, already scaled for the display; the caller recomputes on a
//  DPI change.
//
//  Three coordinate spaces:
//
//    surface  — (0, 0) at the top-left of the whole view, padding included.
//    terminal — the same, with the padding removed.
//    grid     — cells.

import Foundation

struct CellSize: Equatable {
    var width: UInt32
    var height: UInt32
}

struct ScreenSize: Equatable {
    var width: UInt32
    var height: UInt32

    func subtracting(_ padding: EdgePadding) -> ScreenSize {
        ScreenSize(
            width: width &- min(width, padding.left + padding.right),
            height: height &- min(height, padding.top + padding.bottom))
    }

    /// Space left over once the grid and its padding are laid out. Non-zero
    /// whenever the view isn't an exact multiple of the cell size, which is
    /// almost always.
    ///
    /// `self` is the whole screen, padding included — `padding` is subtracted
    /// here, so handing it the terminal size would take it off twice.
    func blankPadding(
        _ padding: EdgePadding, grid: GridDimensions, cell: CellSize
    )
        -> EdgePadding
    {
        let gridWidth = UInt32(grid.columns) * cell.width
        let gridHeight = UInt32(grid.rows) * cell.height
        let paddedWidth = gridWidth + (padding.left + padding.right)
        let paddedHeight = gridHeight + (padding.top + padding.bottom)

        // Saturating: at a 1x1 view the padding alone can exceed the screen.
        return EdgePadding(
            top: 0,
            bottom: height > paddedHeight ? height - paddedHeight : 0,
            right: width > paddedWidth ? width - paddedWidth : 0,
            left: 0)
    }
}

struct GridDimensions: Equatable {
    var columns: UInt16 = 0
    var rows: UInt16 = 0

    init(columns: UInt16 = 0, rows: UInt16 = 0) {
        self.columns = columns
        self.rows = rows
    }

    init(screen: ScreenSize, cell: CellSize) {
        let cols = Double(screen.width) / Double(max(1, cell.width))
        let rws = Double(screen.height) / Double(max(1, cell.height))
        columns = UInt16(max(1, min(Double(UInt16.max), cols.rounded(.down))))
        rows = UInt16(max(1, min(Double(UInt16.max), rws.rounded(.down))))
    }
}

struct EdgePadding: Equatable {
    var top: UInt32 = 0
    var bottom: UInt32 = 0
    var right: UInt32 = 0
    var left: UInt32 = 0

    /// Split the leftover space evenly on both axes.
    static func balanced(
        screen: ScreenSize, grid: GridDimensions, cell: CellSize
    )
        -> EdgePadding
    {
        let gridWidth = Double(grid.columns) * Double(cell.width)
        let gridHeight = Double(grid.rows) * Double(cell.height)
        let spaceRight = Double(screen.width) - gridWidth
        let spaceBottom = Double(screen.height) - gridHeight

        let padRight = (spaceRight / 2).rounded(.down)
        let padBottom = (spaceBottom / 2).rounded(.down)

        return EdgePadding(
            top: UInt32(max(0, padBottom)),
            bottom: UInt32(max(0, padBottom)),
            right: UInt32(max(0, padRight)),
            left: UInt32(max(0, padRight)))
    }

    func adding(_ other: EdgePadding) -> EdgePadding {
        EdgePadding(
            top: top + other.top, bottom: bottom + other.bottom,
            right: right + other.right, left: left + other.left)
    }
}

/// How to distribute whitespace that doesn't divide evenly into cells.
enum PaddingBalance {
    /// Apply the explicit padding as given and leave the slack at the
    /// right and bottom.
    case none
    /// Balance, but cap the top so the first row doesn't drift far from the
    /// top of the window; the excess goes to the bottom.
    case balanced
    /// Split the slack equally on all sides, centring the grid.
    case equal
}

struct RendererSize {
    var screen: ScreenSize
    var cell: CellSize
    var padding: EdgePadding

    /// Grid dimensions for this size.
    var grid: GridDimensions {
        GridDimensions(screen: screen.subtracting(padding), cell: cell)
    }

    /// The screen minus padding.
    var terminal: ScreenSize { screen.subtracting(padding) }

    mutating func balancePadding(explicit: EdgePadding, mode: PaddingBalance) {
        // Set the explicit padding first so `grid` is computed against it.
        padding = explicit
        guard mode != .none else { return }

        padding = .balanced(screen: screen, grid: grid, cell: cell)

        if mode == .balanced {
            // Cap the top at half the explicit horizontal padding plus half
            // a cell; anything beyond that goes to the bottom.
            let maxTop = (explicit.left + explicit.right + cell.width) / 2
            let shift = padding.top > maxTop ? padding.top - maxTop : 0
            padding.top -= shift
            padding.bottom += shift
        }
    }

    /// Grid cell containing a point in surface coordinates, clamped to the
    /// grid.
    func gridCoordinate(surfaceX x: Double, surfaceY y: Double) -> (col: UInt16, row: UInt16) {
        let g = grid
        let tx = max(0, x - Double(padding.left))
        let ty = max(0, y - Double(padding.top))
        let col = UInt16(
            min(Double(g.columns - 1), (tx / Double(max(1, cell.width))).rounded(.down)))
        let row = UInt16(min(Double(g.rows - 1), (ty / Double(max(1, cell.height))).rounded(.down)))
        return (col, row)
    }
}
