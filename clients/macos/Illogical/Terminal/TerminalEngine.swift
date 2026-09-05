//  TerminalEngine.swift
//  The client's own libghostty-vt terminal.
//
//  This is what makes the architecture work: the server ships raw PTY bytes and
//  a binary snapshot, and we run the *same* VT engine it does. Two replicas of
//  one state machine.
//
//  Threading: bytes arrive on the connection's reader thread and are applied
//  immediately, under `lock`. The view asks for a `Grid` on the main thread,
//  which takes the same lock only long enough to update the render state and
//  copy out a value type. Drawing then happens with no lock held — the shape
//  libghostty's two-phase render update is designed for.

import Foundation
import GhosttyVt

final class TerminalEngine: @unchecked Sendable {
    private var terminal: GhosttyTerminal?
    private var renderState: GhosttyRenderState?
    private let lock = NSLock()

    private(set) var cols: UInt16
    private(set) var rows: UInt16

    /// Set when new bytes have been applied and the view should redraw.
    private var dirty = true

    init(cols: UInt16 = 80, rows: UInt16 = 24) throws {
        self.cols = cols
        self.rows = rows

        var term: GhosttyTerminal?
        try check("ghostty_terminal_new") { ghostty_terminal_new(nil, &term, cols, rows) }
        self.terminal = term

        var state: GhosttyRenderState?
        try check("ghostty_render_state_new") { ghostty_render_state_new(nil, &state) }
        self.renderState = state

        applyThemeLocked()
    }

    /// Default foreground/background for cells that carry no explicit colour.
    ///
    /// libghostty defaults to white on black. Superlogical's terminal sits on
    /// the same dark blue ground as its chrome, so the window reads as one
    /// surface rather than a black rectangle in a blue frame.
    enum Theme {
        static let background = GhosttyColorRgb(r: 0x0C, g: 0x1F, b: 0x2F)
        static let foreground = GhosttyColorRgb(r: 0xC8, g: 0xD6, b: 0xE0)
        static let cursor = GhosttyColorRgb(r: 0xC8, g: 0xD6, b: 0xE0)
    }

    private func applyThemeLocked() {
        guard let terminal else { return }
        var background = Theme.background
        var foreground = Theme.foreground
        var cursor = Theme.cursor
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor)
    }

    deinit {
        if let renderState { ghostty_render_state_free(renderState) }
        if let terminal { ghostty_terminal_free(terminal) }
    }

    /// Replace our terminal with one decoded from a server snapshot.
    ///
    /// This is the attach path: the snapshot carries the screen the server
    /// already has, so we adopt it wholesale instead of replaying history.
    func adopt(terminal newTerminal: GhosttyTerminal, cols: UInt16, rows: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        if let terminal { ghostty_terminal_free(terminal) }
        terminal = newTerminal
        self.cols = cols
        self.rows = rows
        // A snapshot-decoded terminal carries libghostty's defaults, not ours.
        applyThemeLocked()
        dirty = true
    }

    /// Apply raw, unprocessed PTY bytes.
    func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let terminal else { return }
        ghostty_terminal_vt_write(
            terminal, base.assumingMemoryBound(to: UInt8.self), bytes.count)
        dirty = true
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { write($0) }
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal, cols > 0, rows > 0 else { return }
        _ = ghostty_terminal_resize(terminal, cols, rows, cellWidth, cellHeight)
        self.cols = cols
        self.rows = rows
        dirty = true
    }

    var needsDisplay: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dirty
    }

    /// Update the render state and copy out a drawable snapshot of the grid.
    ///
    /// The lock is held only for the copy. Drawing happens after it is released.
    func grid() -> Grid? {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal, let renderState else { return nil }

        guard ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS else {
            return nil
        }
        dirty = false

        var colCount: UInt16 = 0
        var rowCount: UInt16 = 0
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLS, &colCount)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROWS, &rowCount)

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)

        var cursorVisible = false
        _ = ghostty_render_state_get(
            renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursorVisible)
        var cursorX: UInt16 = 0
        var cursorY: UInt16 = 0
        var cursorHasViewport = false
        _ = ghostty_render_state_get(
            renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cursorHasViewport)
        if cursorHasViewport {
            _ = ghostty_render_state_get(
                renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cursorX)
            _ = ghostty_render_state_get(
                renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cursorY)
        }

        var rowsOut: [Grid.Row] = []
        rowsOut.reserveCapacity(Int(rowCount))

        var iterator: GhosttyRenderStateRowIterator?
        guard
            ghostty_render_state_row_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS,
            ghostty_render_state_get(
                renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator) == GHOSTTY_SUCCESS
        else { return nil }
        defer { ghostty_render_state_row_iterator_free(iterator) }

        var cells: GhosttyRenderStateRowCells?
        guard ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS else {
            return nil
        }
        defer { ghostty_render_state_row_cells_free(cells) }

        var utf8 = [UInt8](repeating: 0, count: 64)

        while ghostty_render_state_row_iterator_next(iterator) {
            guard
                ghostty_render_state_row_get(
                    iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS
            else { continue }

            var rowCells: [Grid.Cell] = []
            rowCells.reserveCapacity(Int(colCount))

            while ghostty_render_state_row_cells_next(cells) {
                var graphemeLen: UInt32 = 0
                _ = ghostty_render_state_row_cells_get(
                    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &graphemeLen)

                var text = ""
                if graphemeLen > 0 {
                    text = utf8.withUnsafeMutableBufferPointer { buffer -> String in
                        var out = GhosttyBuffer()
                        out.ptr = buffer.baseAddress
                        out.cap = buffer.count
                        out.len = 0
                        let result = ghostty_render_state_row_cells_get(
                            cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &out)
                        guard result == GHOSTTY_SUCCESS, out.len > 0 else { return "" }
                        return String(
                            decoding: UnsafeBufferPointer(
                                start: buffer.baseAddress, count: out.len),
                            as: UTF8.self)
                    }
                }

                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                ghostty_style_default(&style)
                var hasStyling = false
                _ = ghostty_render_state_row_cells_get(
                    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
                if hasStyling {
                    _ = ghostty_render_state_row_cells_get(
                        cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                }

                var fg = GhosttyColorRgb()
                let hasFg =
                    ghostty_render_state_row_cells_get(
                        cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS
                var bg = GhosttyColorRgb()
                let hasBg =
                    ghostty_render_state_row_cells_get(
                        cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS

                var selected = false
                _ = ghostty_render_state_row_cells_get(
                    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected)

                rowCells.append(
                    Grid.Cell(
                        text: text,
                        foreground: hasFg ? .init(fg) : nil,
                        background: hasBg ? .init(bg) : nil,
                        bold: style.bold,
                        italic: style.italic,
                        faint: style.faint,
                        underline: style.underline != 0,
                        strikethrough: style.strikethrough,
                        inverse: style.inverse,
                        invisible: style.invisible,
                        selected: selected))
            }
            rowsOut.append(Grid.Row(cells: rowCells))
        }

        return Grid(
            cols: Int(colCount),
            rows: Int(rowCount),
            lines: rowsOut,
            foreground: .init(colors.foreground),
            background: .init(colors.background),
            cursor: cursorVisible && cursorHasViewport
                ? Grid.Cursor(x: Int(cursorX), y: Int(cursorY)) : nil)
    }
}

/// A drawable copy of the terminal grid. A value type on purpose: once the view
/// has one it can draw without holding any lock.
struct Grid {
    struct RGB: Equatable {
        var r: UInt8
        var g: UInt8
        var b: UInt8

        init(_ c: GhosttyColorRgb) {
            self.r = c.r
            self.g = c.g
            self.b = c.b
        }
    }

    struct Cell {
        var text: String
        var foreground: RGB?
        var background: RGB?
        var bold: Bool
        var italic: Bool
        var faint: Bool
        var underline: Bool
        var strikethrough: Bool
        var inverse: Bool
        var invisible: Bool
        var selected: Bool
    }

    struct Row {
        var cells: [Cell]
    }

    struct Cursor {
        var x: Int
        var y: Int
    }

    var cols: Int
    var rows: Int
    var lines: [Row]
    var foreground: RGB
    var background: RGB
    var cursor: Cursor?
}
