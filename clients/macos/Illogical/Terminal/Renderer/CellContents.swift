//  CellContents.swift
//  The CPU-side mirror of what the GPU will draw.
//
//  Ported from libghostty's `src/renderer/cell.zig`.
//
//  The shape of this structure is the whole point of row-wise dirty
//  tracking. Backgrounds are a flat array indexed by cell, so clearing a row
//  is one memset. Foreground elements are a list *per row*, so clearing a row
//  is one `removeAll(keepingCapacity:)` — no compaction, no re-walking the
//  other rows. A frame that changes one line rebuilds one line.
//
//  Row `y` lives at `fgRows[y + 1]`. Index 0 holds the block cursor, which
//  must be drawn before the text so the text lands on top of it, and index
//  `rows + 1` holds the other cursor styles, which draw over the text.

import Foundation

struct CellContents {
    private(set) var columns: Int = 0
    private(set) var rows: Int = 0

    /// Per-cell background colours, indexed `row * columns + col`. Uploaded
    /// verbatim and read by the background shader.
    private(set) var bgCells: [IllogicalCellBg] = []

    /// Foreground instances per row, plus the two cursor slots.
    private(set) var fgRows: [ContiguousArray<IllogicalCellText>] = []

    /// Resize, invalidating everything.
    mutating func resize(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows

        bgCells = [IllogicalCellBg](
            repeating: IllogicalCellBg(0, 0, 0, 0), count: rows * columns)

        fgRows = Array(repeating: ContiguousArray<IllogicalCellText>(), count: rows + 2)
        // A row can hold a glyph, an underline and a strikethrough per
        // column. Reserving three per column covers the common cases without
        // reserving for every combination; combining marks and multi-glyph
        // substitutions can still exceed it, so we never assume the capacity.
        for i in 1..<(rows + 1) {
            fgRows[i].reserveCapacity(columns * 3)
        }
        // The cursor slots only ever hold one instance each.
        fgRows[0].reserveCapacity(1)
        fgRows[rows + 1].reserveCapacity(1)
    }

    /// Clear everything without giving back capacity.
    mutating func reset() {
        for i in bgCells.indices { bgCells[i] = IllogicalCellBg(0, 0, 0, 0) }
        for i in fgRows.indices { fgRows[i].removeAll(keepingCapacity: true) }
    }

    /// Clear one row.
    mutating func clear(row y: Int) {
        guard y >= 0, y < rows else { return }
        let base = y * columns
        for i in base..<(base + columns) { bgCells[i] = IllogicalCellBg(0, 0, 0, 0) }
        fgRows[y + 1].removeAll(keepingCapacity: true)
    }

    mutating func setBackground(row y: Int, column x: Int, _ color: IllogicalCellBg) {
        guard y >= 0, y < rows, x >= 0, x < columns else { return }
        bgCells[y * columns + x] = color
    }

    /// Append a foreground instance. Adding the same cell twice duplicates
    /// it in the vertex buffer, so callers clear the row first.
    mutating func add(row y: Int, _ cell: IllogicalCellText) {
        guard y >= 0, y < rows else { return }
        fgRows[y + 1].append(cell)
    }

    /// Set (or clear, with nil) the cursor sprite.
    ///
    /// A block cursor goes first so text draws over it; every other style
    /// goes last so it draws over the text.
    mutating func setCursor(_ cell: IllogicalCellText?, style: CursorStyle?) {
        guard rows > 0 else { return }
        fgRows[0].removeAll(keepingCapacity: true)
        fgRows[rows + 1].removeAll(keepingCapacity: true)

        guard let cell, let style else { return }
        switch style {
        case .block: fgRows[0].append(cell)
        case .blockHollow, .bar, .underline, .lock: fgRows[rows + 1].append(cell)
        }
    }

    /// Total foreground instances, i.e. the instance count for the draw.
    var foregroundCount: Int {
        var total = 0
        for row in fgRows { total += row.count }
        return total
    }
}

/// Cursor shapes the renderer knows how to draw. A superset of the terminal's
/// own styles: the hollow block and the lock are renderer states, not
/// anything the program on the other end asked for.
enum CursorStyle {
    case block
    case blockHollow
    case bar
    case underline
    case lock
}
