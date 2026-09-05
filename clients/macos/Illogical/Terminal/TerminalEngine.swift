//  TerminalEngine.swift
//  The client's own libghostty-vt terminal.
//
//  This is what makes the architecture work: the server ships raw PTY bytes
//  and a binary snapshot, and we run the *same* VT engine it does. Two
//  replicas of one state machine.
//
//  Threading, and why it is shaped this way:
//
//  Bytes arrive on the connection's reader thread and are applied
//  immediately under `lock`. The renderer runs on its own thread and calls
//  `updateSnapshot`, which takes that lock for exactly one call —
//  `ghostty_render_state_begin_update` — and then releases it. Everything
//  after that reads memory owned by the render state, so the reader thread
//  keeps feeding the terminal at full speed while a frame is assembled.
//
//  That two-phase split is the whole reason libghostty's render state exists:
//  "This allows the render state to minimally impact terminal IO performance
//  and also allows the renderer to be safely multi-threaded." (render.h)

import Foundation
import GhosttyVt

final class TerminalEngine: @unchecked Sendable {
    private var terminal: GhosttyTerminal?
    private var renderState: GhosttyRenderState?
    private let lock = NSLock()

    /// Reused across frames so extraction allocates nothing.
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var graphemeScratch = [UInt32](repeating: 0, count: 64)

    private(set) var cols: UInt16
    private(set) var rows: UInt16

    /// Set when bytes have been applied and a frame is owed. Read from the
    /// display link every tick, so it is an atomic rather than lock-guarded:
    /// an idle terminal must not cost a lock acquisition 120 times a second.
    private let dirtyFlag = Atomic(true)

    /// Called when the engine goes from clean to dirty, so the view can
    /// restart a paused display link. An idle terminal should cost nothing,
    /// which means the display link has to actually stop.
    var onWake: (@Sendable () -> Void)?

    init(cols: UInt16 = 80, rows: UInt16 = 24) throws {
        self.cols = cols
        self.rows = rows

        var term: GhosttyTerminal?
        try check("ghostty_terminal_new") { ghostty_terminal_new(nil, &term, cols, rows) }
        self.terminal = term

        var state: GhosttyRenderState?
        try check("ghostty_render_state_new") { ghostty_render_state_new(nil, &state) }
        self.renderState = state

        var iterator: GhosttyRenderStateRowIterator?
        try check("ghostty_render_state_row_iterator_new") {
            ghostty_render_state_row_iterator_new(nil, &iterator)
        }
        self.rowIterator = iterator

        var cells: GhosttyRenderStateRowCells?
        try check("ghostty_render_state_row_cells_new") {
            ghostty_render_state_row_cells_new(nil, &cells)
        }
        self.rowCells = cells

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
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let renderState { ghostty_render_state_free(renderState) }
        if let terminal { ghostty_terminal_free(terminal) }
    }

    /// Replace our terminal with one decoded from a server snapshot.
    ///
    /// This is the attach path: the snapshot carries the screen the server
    /// already has, so we adopt it wholesale instead of replaying history.
    func adopt(terminal newTerminal: GhosttyTerminal, cols: UInt16, rows: UInt16) {
        lock.lock()
        if let terminal { ghostty_terminal_free(terminal) }
        terminal = newTerminal
        self.cols = cols
        self.rows = rows
        // A snapshot-decoded terminal carries libghostty's defaults, not ours.
        applyThemeLocked()
        lock.unlock()
        markDirty()
    }

    /// Apply raw, unprocessed PTY bytes.
    func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        lock.lock()
        if let terminal {
            ghostty_terminal_vt_write(
                terminal, base.assumingMemoryBound(to: UInt8.self), bytes.count)
        }
        lock.unlock()
        markDirty()
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { write($0) }
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        guard cols > 0, rows > 0 else { return }
        lock.lock()
        if let terminal {
            _ = ghostty_terminal_resize(terminal, cols, rows, cellWidth, cellHeight)
            self.cols = cols
            self.rows = rows
        }
        lock.unlock()
        markDirty()
    }

    private func markDirty() {
        // Only wake on the clean -> dirty edge. A terminal spewing output
        // must not post a wakeup per write.
        if !dirtyFlag.exchange(true) {
            onWake?()
        }
    }

    // MARK: - Render source

    var isDirty: Bool { dirtyFlag.load() }

    /// Take a consistent view of the terminal into `snapshot`.
    ///
    /// The terminal lock is held for the `begin_update` call only.
    func updateSnapshot(into snapshot: TerminalSnapshot) -> Bool {
        guard let renderState, let rowIterator, let rowCells else { return false }

        lock.lock()
        guard let terminal else {
            lock.unlock()
            return false
        }
        let beginResult = ghostty_render_state_begin_update(renderState, terminal)
        lock.unlock()

        guard beginResult == GHOSTTY_SUCCESS else { return false }
        dirtyFlag.store(false)

        // Deferred work that needs no terminal access. The reader thread is
        // free to keep writing from here on.
        guard ghostty_render_state_end_update(renderState) == GHOSTTY_SUCCESS else {
            return false
        }

        var colCount: UInt16 = 0
        var rowCount: UInt16 = 0
        var dirty: GhosttyRenderStateDirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLS, &colCount)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROWS, &rowCount)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)

        guard colCount > 0, rowCount > 0 else { return false }

        // A size change invalidates every row, whatever the dirty state says.
        let sizeChanged =
            snapshot.columns != Int(colCount) || snapshot.rows != Int(rowCount)
        snapshot.resize(columns: Int(colCount), rows: Int(rowCount))

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)

        snapshot.background = PackedRGB(
            r: colors.background.r, g: colors.background.g, b: colors.background.b)
        snapshot.foreground = PackedRGB(
            r: colors.foreground.r, g: colors.foreground.g, b: colors.foreground.b)
        snapshot.cursorColor =
            colors.cursor_has_value
            ? PackedRGB(r: colors.cursor.r, g: colors.cursor.g, b: colors.cursor.b)
            : .none

        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)
        snapshot.cursor = SnapshotCursor(
            hasViewport: cursor.viewport_has_value,
            x: cursor.viewport_x,
            y: cursor.viewport_y,
            wideTail: cursor.wide_tail,
            visible: cursor.visible,
            blinking: cursor.blinking,
            passwordInput: cursor.password_input,
            style: Self.cursorStyle(cursor.visual_style))

        snapshot.dirty = sizeChanged ? .full : Self.dirtyState(dirty)

        // Point the reusable iterator at this update's rows.
        var iterator: GhosttyRenderStateRowIterator? = rowIterator
        guard
            ghostty_render_state_get(
                renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator)
                == GHOSTTY_SUCCESS
        else { return false }

        snapshot.clearRowDirty()

        if snapshot.dirty == .full {
            var y = 0
            while ghostty_render_state_row_iterator_next(rowIterator) {
                if y < snapshot.rows {
                    extractRow(
                        into: snapshot, y: y, iterator: rowIterator, cells: rowCells,
                        colors: &colors)
                }
                y += 1
            }
        } else if snapshot.dirty == .partial {
            var y: UInt16 = 0
            while ghostty_render_state_row_iterator_next_dirty(rowIterator, &y) {
                if Int(y) < snapshot.rows {
                    extractRow(
                        into: snapshot, y: Int(y), iterator: rowIterator, cells: rowCells,
                        colors: &colors)
                }
            }
        }

        // Consume the dirty state. Safe here rather than after the GPU work
        // because what we just built — the snapshot — is the durable copy;
        // the draw only uploads it.
        _ = ghostty_render_state_clean(renderState)
        return true
    }

    /// Pull one row's cells into the snapshot.
    private func extractRow(
        into snapshot: TerminalSnapshot,
        y: Int,
        iterator: GhosttyRenderStateRowIterator,
        cells: GhosttyRenderStateRowCells,
        colors: inout GhosttyRenderStateColors
    ) {
        snapshot.rowDirty[y] = true
        snapshot.rowData[y].reset(columns: snapshot.columns)

        // One call per row for selection, rather than one per cell. The
        // header recommends exactly this for renderers that work in spans.
        var selection = GhosttyRenderStateRowSelection()
        selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
        if ghostty_render_state_row_get(
            iterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
        {
            snapshot.rowData[y].selection = (selection.start_x, selection.end_x)
        }

        var cellsHandle: GhosttyRenderStateRowCells? = cells
        guard
            ghostty_render_state_row_get(
                iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle) == GHOSTTY_SUCCESS
        else { return }

        var x = 0
        while ghostty_render_state_row_cells_next(cells) {
            guard x < snapshot.columns else { break }
            defer { x += 1 }

            var raw: GhosttyCell = 0
            var hasStyling = false
            var graphemeLen: UInt32 = 0
            withUnsafeMutablePointer(to: &raw) { rawPtr in
                withUnsafeMutablePointer(to: &hasStyling) { stylingPtr in
                    withUnsafeMutablePointer(to: &graphemeLen) { lenPtr in
                        var keys: [GhosttyRenderStateRowCellsData] = [
                            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING,
                            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                        ]
                        var values: [UnsafeMutableRawPointer?] = [
                            UnsafeMutableRawPointer(rawPtr),
                            UnsafeMutableRawPointer(stylingPtr),
                            UnsafeMutableRawPointer(lenPtr),
                        ]
                        _ = ghostty_render_state_row_cells_get_multi(
                            cells, 3, &keys, &values, nil)
                    }
                }
            }

            var cell = RenderCell()
            cell.hasStyling = hasStyling

            var codepoint: UInt32 = 0
            var wide: GhosttyCellWide = GHOSTTY_CELL_WIDE_NARROW
            var hasText = false
            withUnsafeMutablePointer(to: &codepoint) { cpPtr in
                withUnsafeMutablePointer(to: &wide) { widePtr in
                    withUnsafeMutablePointer(to: &hasText) { textPtr in
                        var keys: [GhosttyCellData] = [
                            GHOSTTY_CELL_DATA_CODEPOINT,
                            GHOSTTY_CELL_DATA_WIDE,
                            GHOSTTY_CELL_DATA_HAS_TEXT,
                        ]
                        var values: [UnsafeMutableRawPointer?] = [
                            UnsafeMutableRawPointer(cpPtr),
                            UnsafeMutableRawPointer(widePtr),
                            UnsafeMutableRawPointer(textPtr),
                        ]
                        _ = ghostty_cell_get_multi(raw, 3, &keys, &values, nil)
                    }
                }
            }

            cell.codepoint = codepoint
            cell.hasText = hasText
            cell.wide = CellWide(rawValue: UInt8(truncatingIfNeeded: wide.rawValue)) ?? .narrow

            if hasStyling {
                var style = GhosttyStyle()
                ghostty_style_default(&style)
                style.size = MemoryLayout<GhosttyStyle>.size
                if ghostty_render_state_row_cells_get(
                    cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS
                {
                    var flags: CellFlags = []
                    if style.bold { flags.insert(.bold) }
                    if style.italic { flags.insert(.italic) }
                    if style.faint { flags.insert(.faint) }
                    if style.blink { flags.insert(.blink) }
                    if style.inverse { flags.insert(.inverse) }
                    if style.invisible { flags.insert(.invisible) }
                    if style.strikethrough { flags.insert(.strikethrough) }
                    if style.overline { flags.insert(.overline) }
                    cell.flags = flags
                    cell.underline =
                        CellUnderline(rawValue: UInt8(truncatingIfNeeded: style.underline))
                        ?? .none
                    // Foreground and background are resolved for us, but the
                    // underline colour is not, so look up the palette here.
                    cell.underlineColor = Self.resolve(style.underline_color, colors: &colors)
                }
            }

            // These return GHOSTTY_INVALID_VALUE when the cell has no
            // explicit colour, which is the common case and not an error.
            var fg = GhosttyColorRgb()
            if ghostty_render_state_row_cells_get(
                cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS
            {
                cell.fg = PackedRGB(r: fg.r, g: fg.g, b: fg.b)
            }
            var bg = GhosttyColorRgb()
            if ghostty_render_state_row_cells_get(
                cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS
            {
                cell.bg = PackedRGB(r: bg.r, g: bg.g, b: bg.b)
            }

            // graphemeLen counts the base codepoint, so anything above one
            // means there are combining marks to fetch.
            if graphemeLen > 1 {
                let extra = Int(graphemeLen)
                if graphemeScratch.count < extra {
                    graphemeScratch = [UInt32](repeating: 0, count: extra * 2)
                }
                let ok = graphemeScratch.withUnsafeMutableBufferPointer { buf -> Bool in
                    ghostty_render_state_row_cells_get(
                        cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                        buf.baseAddress) == GHOSTTY_SUCCESS
                }
                if ok {
                    cell.graphemeOffset = UInt32(snapshot.rowData[y].graphemes.count)
                    cell.graphemeLen = graphemeLen - 1
                    // Skip index 0: that is the base codepoint, which we
                    // already have.
                    for i in 1..<extra {
                        snapshot.rowData[y].graphemes.append(graphemeScratch[i])
                    }
                }
            }

            snapshot.rowData[y].cells[x] = cell
        }
    }

    private static func resolve(
        _ color: GhosttyStyleColor, colors: inout GhosttyRenderStateColors
    ) -> PackedRGB {
        switch color.tag {
        case GHOSTTY_STYLE_COLOR_RGB:
            let rgb = color.value.rgb
            return PackedRGB(r: rgb.r, g: rgb.g, b: rgb.b)
        case GHOSTTY_STYLE_COLOR_PALETTE:
            let index = Int(color.value.palette)
            return withUnsafeBytes(of: &colors.palette) { raw -> PackedRGB in
                let entries = raw.bindMemory(to: GhosttyColorRgb.self)
                guard index < entries.count else { return .none }
                let c = entries[index]
                return PackedRGB(r: c.r, g: c.g, b: c.b)
            }
        default:
            return .none
        }
    }

    private static func dirtyState(_ v: GhosttyRenderStateDirty) -> RenderDirty {
        switch v {
        case GHOSTTY_RENDER_STATE_DIRTY_FULL: return .full
        case GHOSTTY_RENDER_STATE_DIRTY_PARTIAL: return .partial
        default: return .clean
        }
    }

    private static func cursorStyle(
        _ v: GhosttyRenderStateCursorVisualStyle
    )
        -> TerminalCursorStyle
    {
        switch v {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: return .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: return .blockHollow
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: return .underline
        default: return .block
        }
    }
}

extension TerminalEngine: TerminalRenderSource {}
