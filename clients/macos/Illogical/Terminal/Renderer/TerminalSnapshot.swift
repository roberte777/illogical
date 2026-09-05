//  TerminalSnapshot.swift
//  What the renderer reads instead of the terminal.
//
//  The terminal is being written to by the connection's reader thread at all
//  times. libghostty's render state exists precisely so a renderer can take a
//  consistent view of it while that continues, and this is the shape that
//  view takes on our side.
//
//  Rows persist across frames. Only dirty rows are refreshed, so a frame that
//  changes one line re-reads one line — but the renderer can still look at
//  any row (it needs the cursor's row, which is usually clean).

import Foundation

/// libghostty's two-layer dirty state.
enum RenderDirty: UInt8 {
    case clean = 0
    /// Some rows changed; consult the per-row flags.
    case partial = 1
    /// Everything changed.
    case full = 2
}

/// Cursor style as the terminal asks for it, before the renderer's own
/// states (unfocused, password input) are layered on.
enum TerminalCursorStyle: UInt8 {
    case bar = 0
    case block = 1
    case blockHollow = 2
    case underline = 3
}

struct SnapshotCursor {
    /// False when the cursor is scrolled out of the viewport.
    var hasViewport = false
    var x: UInt16 = 0
    var y: UInt16 = 0
    /// The cursor is sitting on the second half of a wide character.
    var wideTail = false
    var visible = false
    var blinking = false
    var passwordInput = false
    var style: TerminalCursorStyle = .block
}

/// A consistent view of the terminal for one frame.
final class TerminalSnapshot {
    var columns = 0
    var rows = 0
    var dirty: RenderDirty = .clean

    var background = PackedRGB(r: 0, g: 0, b: 0)
    var foreground = PackedRGB(r: 255, g: 255, b: 255)
    /// Set only when the program asked for a cursor colour (OSC 12).
    var cursorColor = PackedRGB.none

    var cursor = SnapshotCursor()

    /// One entry per row, persistent across frames.
    var rowData: [RenderRow] = []
    /// Which rows were refreshed this frame.
    var rowDirty: [Bool] = []

    func resize(columns: Int, rows: Int) {
        guard columns != self.columns || rows != self.rows else { return }
        self.columns = columns
        self.rows = rows
        rowData = Array(repeating: RenderRow(), count: rows)
        for i in rowData.indices { rowData[i].reset(columns: columns) }
        rowDirty = Array(repeating: true, count: rows)
    }

    func clearRowDirty() {
        for i in rowDirty.indices { rowDirty[i] = false }
    }

    /// The cell under the cursor, or nil if the cursor isn't in the viewport.
    var cursorCell: RenderCell? {
        guard cursor.hasViewport else { return nil }
        let y = Int(cursor.y)
        let x = Int(cursor.x)
        guard y < rowData.count, x < rowData[y].cells.count else { return nil }
        return rowData[y].cells[x]
    }
}
