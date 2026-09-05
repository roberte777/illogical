//  TerminalSelection.swift
//  Selection, copy and paste, built on libghostty's own selection primitives.
//
//  Selections are expressed as grid *references*, not row/column pairs, because
//  the grid moves underneath them: output scrolls, the viewport shifts, reflow
//  on resize rewrites rows. libghostty resolves a reference against the live
//  screen, so a selection made three screens ago still means the same text.
//
//  Word and line selection go through `select_word` / `select_line` rather than
//  being reimplemented here: they already know about wide characters, grapheme
//  clusters and semantic prompt boundaries.

import AppKit
import Foundation
import GhosttyVt

extension TerminalEngine {
    /// A grid reference for a viewport cell, or nil if it is off-screen.
    private func gridRef(column: UInt16, row: UInt16) -> GhosttyGridRef? {
        guard let handle = terminalHandle else { return nil }
        // Viewport coordinates: the reference is resolved against what is on
        // screen now, then survives scrolling and reflow on its own.
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate.x = column
        point.value.coordinate.y = UInt32(row)

        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(handle, point, &ref) == GHOSTTY_SUCCESS else {
            return nil
        }
        return ref
    }

    private func apply(_ selection: GhosttySelection?) {
        guard let handle = terminalHandle else { return }
        if var selection {
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        } else {
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        }
        markDirty()
    }

    func select(from: (column: UInt16, row: UInt16), to: (column: UInt16, row: UInt16)) {
        withLock {
            guard let start = gridRef(column: from.column, row: from.row),
                let end = gridRef(column: to.column, row: to.row)
            else { return }
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            selection.start = start
            selection.end = end
            apply(selection)
        }
    }

    func selectWord(atColumn column: UInt16, row: UInt16) {
        withLock {
            guard let handle = terminalHandle, let ref = gridRef(column: column, row: row) else {
                return
            }
            var options = GhosttyTerminalSelectWordOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
            options.ref = ref
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            guard ghostty_terminal_select_word(handle, &options, &selection) == GHOSTTY_SUCCESS
            else { return }
            apply(selection)
        }
    }

    func selectLine(atColumn column: UInt16, row: UInt16) {
        withLock {
            guard let handle = terminalHandle, let ref = gridRef(column: column, row: row) else {
                return
            }
            var options = GhosttyTerminalSelectLineOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
            options.ref = ref
            options.semantic_prompt_boundary = true
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            guard ghostty_terminal_select_line(handle, &options, &selection) == GHOSTTY_SUCCESS
            else { return }
            apply(selection)
        }
    }

    func selectAll() {
        withLock {
            guard rows > 0, cols > 0,
                let start = gridRef(column: 0, row: 0),
                let end = gridRef(column: cols - 1, row: rows - 1)
            else { return }
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            selection.start = start
            selection.end = end
            apply(selection)
        }
    }

    func clearSelection() {
        withLock { apply(nil) }
    }

    var hasSelection: Bool {
        withLock {
            guard let handle = terminalHandle else { return false }
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            return ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SELECTION, &selection)
                == GHOSTTY_SUCCESS
        }
    }

    /// The selected text as plain text, for the clipboard.
    func selectedText() -> String? {
        withLock { () -> String? in
            guard let handle = terminalHandle else { return nil }
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            guard
                ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SELECTION, &selection)
                    == GHOSTTY_SUCCESS
            else { return nil }

            return withUnsafePointer(to: &selection) { selectionPointer -> String? in
                var options = GhosttyTerminalSelectionFormatOptions()
                options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
                options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
                options.unwrap = true
                options.trim = true
                options.selection = selectionPointer

                var pointer: UnsafeMutablePointer<UInt8>?
                var length = 0
                guard
                    ghostty_terminal_selection_format_alloc(
                        handle, nil, options, &pointer, &length) == GHOSTTY_SUCCESS,
                    let pointer
                else { return nil }
                defer { ghostty_free(nil, pointer, length) }
                return String(
                    decoding: UnsafeBufferPointer(start: pointer, count: length),
                    as: UTF8.self)
            }
        }
    }

    /// Encode pasted text, honouring bracketed paste when the program asked
    /// for it — otherwise a paste can be executed as commands.
    func encodePaste(_ text: String) -> [UInt8]? {
        withLock { () -> [UInt8]? in
            guard let handle = terminalHandle else { return nil }
            var bracketed = false
            var mode = GhosttyTerminalModeConfig()
            // The GHOSTTY_MODE_* names are function-like macros, which Swift
            // does not import; call the constructor they expand to. 2004 is
            // bracketed paste, a DEC private mode.
            mode.mode = ghostty_mode_new(2004, false)
            if ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &mode) == GHOSTTY_SUCCESS {
                bracketed = mode.value
            }

            var data = Array(text.utf8).map { CChar(bitPattern: $0) }
            var required = 0
            _ = data.withUnsafeMutableBufferPointer { input in
                ghostty_paste_encode(
                    input.baseAddress, input.count, bracketed, nil, 0, &required)
            }
            guard required > 0 else { return nil }

            var out = [CChar](repeating: 0, count: required)
            var written = 0
            let result = data.withUnsafeMutableBufferPointer { input in
                out.withUnsafeMutableBufferPointer { buffer in
                    ghostty_paste_encode(
                        input.baseAddress, input.count, bracketed,
                        buffer.baseAddress, buffer.count, &written)
                }
            }
            guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
            return out.prefix(written).map { UInt8(bitPattern: $0) }
        }
    }
}
