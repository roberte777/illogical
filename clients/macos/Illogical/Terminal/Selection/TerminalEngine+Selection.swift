//  TerminalEngine+Selection.swift
//  Selection and the clipboard, against the terminal's own state.
//
//  Everything here runs inside `withTerminal`, which holds the engine's lock.
//  That is not caution — it is the only correct place for it. A
//  `GhosttyGridRef` is invalidated by the next mutating call on its terminal,
//  and ours mutates on the reader thread every time the PTY says anything, so
//  deriving a ref and using it are one operation or they are a use-after-free.
//
//  The selection we hand the terminal is likewise untracked, and stops being
//  valid the moment it is installed — which is fine, because installing it is
//  what converts it to terminal-owned tracked state. That is why nothing here
//  keeps a `GhosttySelection` around: the terminal is the one place a
//  selection can outlive a frame of output.

import AppKit
import Foundation
import GhosttyVt

extension TerminalEngine {
    // MARK: - Gesture

    /// Begin a click sequence at a point in surface pixels.
    ///
    /// Returns true when the press produced a selection — a double-click on a
    /// word, a triple-click on a line. A plain single click produces none, and
    /// clears whatever was selected, which is what clicking in a terminal has
    /// always done.
    @discardableResult
    func beginSelection(
        at point: CGPoint,
        size: RendererSize,
        timestamp: TimeInterval,
        repeatInterval: TimeInterval,
        rectangle: Bool
    ) -> Bool {
        let produced =
            withTerminal { terminal -> Bool? in
                guard let ref = Self.gridRef(terminal: terminal, at: point, size: size) else {
                    return false
                }
                let selection = selectionGesture.press(
                    terminal: terminal,
                    ref: ref,
                    position: GhosttySurfacePosition(x: point.x, y: point.y),
                    timeNs: UInt64(max(0, timestamp) * 1_000_000_000),
                    repeatIntervalNs: UInt64(max(0, repeatInterval) * 1_000_000_000),
                    rectangle: rectangle)
                Self.install(selection, on: terminal)
                return selection != nil
            } ?? false
        invalidate()
        return produced
    }

    /// Extend the selection to a point in surface pixels.
    func extendSelection(to point: CGPoint, size: RendererSize, rectangle: Bool) {
        withTerminal { terminal -> Bool? in
            guard let ref = Self.gridRef(terminal: terminal, at: point, size: size) else {
                return nil
            }
            guard
                let selection = selectionGesture.drag(
                    terminal: terminal,
                    ref: ref,
                    position: GhosttySurfacePosition(x: point.x, y: point.y),
                    geometry: Self.geometry(size),
                    rectangle: rectangle)
            else { return nil }
            Self.install(selection, on: terminal)
            return true
        }
        invalidate()
    }

    /// Extend the selection to the edge row the pointer is being held past,
    /// after the viewport has moved under it.
    ///
    /// The scrolling itself is not here: the viewport belongs to the client's
    /// scrollback, and this is the half that says what the selection should
    /// become once it has moved.
    func tickSelectionAutoscroll(row: UInt32, column: UInt16, size: RendererSize, rectangle: Bool) {
        withTerminal { terminal -> Bool? in
            guard
                let selection = selectionGesture.autoscrollTick(
                    terminal: terminal,
                    viewport: GhosttyPointCoordinate(x: column, y: row),
                    geometry: Self.geometry(size),
                    rectangle: rectangle)
            else { return nil }
            Self.install(selection, on: terminal)
            return true
        }
        invalidate()
    }

    /// Which way a held drag wants the viewport to move, if either.
    var selectionAutoscroll: GhosttySelectionGestureAutoscroll {
        withTerminal { terminal -> GhosttySelectionGestureAutoscroll? in
            selectionGesture.autoscroll(terminal: terminal)
        } ?? GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
    }

    /// End the click sequence. The selection from the last drag stands.
    func endSelection(at point: CGPoint?, size: RendererSize) {
        withTerminal { terminal -> Bool? in
            let ref = point.flatMap { Self.gridRef(terminal: terminal, at: $0, size: size) }
            selectionGesture.release(terminal: terminal, ref: ref)
            return true
        }
    }

    // MARK: - Whole selections

    func selectAll() {
        withTerminal { terminal -> Bool? in
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            guard ghostty_terminal_select_all(terminal, &selection) == GHOSTTY_SUCCESS else {
                return nil
            }
            Self.install(selection, on: terminal)
            return true
        }
        invalidate()
    }

    func clearSelection() {
        withTerminal { terminal -> Bool? in
            selectionGesture.reset(terminal: terminal)
            Self.install(nil, on: terminal)
            return true
        }
        invalidate()
    }

    var hasSelection: Bool {
        withTerminal { terminal -> Bool? in
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection)
                == GHOSTTY_SUCCESS
        } ?? false
    }

    // MARK: - Clipboard

    /// The selected text, formatted the way a terminal's copy has always
    /// worked: soft-wrapped lines rejoined, trailing whitespace dropped.
    func selectionText() -> String? {
        withTerminal { terminal -> String? in
            var options = GhosttyTerminalSelectionFormatOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            options.unwrap = true
            options.trim = true
            options.selection = nil

            var pointer: UnsafeMutablePointer<UInt8>?
            var length = 0
            guard
                ghostty_terminal_selection_format_alloc(
                    terminal, nil, options, &pointer, &length) == GHOSTTY_SUCCESS,
                let pointer, length > 0
            else { return nil }
            defer { ghostty_free(nil, pointer, length) }
            return String(
                decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
        }
    }

    /// Whether pasting this text would be taken as an attempt to inject a
    /// command — a newline outside bracketed paste, or the bracketed-paste
    /// terminator inside it.
    static func pasteIsSafe(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { buffer in
            buffer.withMemoryRebound(to: CChar.self) { chars in
                ghostty_paste_is_safe(chars.baseAddress, chars.count)
            }
        }
    }

    /// Encode text for the PTY: control bytes stripped, newlines turned into
    /// carriage returns, and the whole thing wrapped in bracketed paste when
    /// the program asked for it (DEC mode 2004).
    func encodePaste(_ text: String) -> [UInt8]? {
        guard !text.isEmpty else { return nil }

        let bracketed =
            withTerminal { terminal -> Bool? in
                var mode = GhosttyTerminalModeConfig(
                    mode: ghostty_mode_new(2004, false), value: false)
                guard
                    ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode)
                        == GHOSTTY_SUCCESS
                else { return false }
                return mode.value
            } ?? false

        // `ghostty_paste_encode` rewrites its input in place, so this must be
        // our own copy of the bytes and not the string's storage.
        var input = Array(text.utf8).map { CChar(bitPattern: $0) }
        var length = 0
        let sized = input.withUnsafeMutableBufferPointer { data -> Int in
            _ = ghostty_paste_encode(
                data.baseAddress, data.count, bracketed, nil, 0, &length)
            return length
        }
        guard sized > 0 else { return nil }

        var output = [CChar](repeating: 0, count: sized)
        var written = 0
        let result = input.withUnsafeMutableBufferPointer { data in
            output.withUnsafeMutableBufferPointer { buffer in
                ghostty_paste_encode(
                    data.baseAddress, data.count, bracketed, buffer.baseAddress, buffer.count,
                    &written)
            }
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return output[0..<written].map { UInt8(bitPattern: $0) }
    }

    // MARK: - Plumbing

    /// The cell under a point in surface pixels.
    ///
    /// Viewport coordinates on purpose: `ghostty_terminal_grid_ref` resolves
    /// them against wherever the viewport currently sits, so this stays
    /// correct while scrolled back into history without knowing the offset.
    private static func gridRef(
        terminal: GhosttyTerminal, at point: CGPoint, size: RendererSize
    ) -> GhosttyGridRef? {
        let cell = size.gridCoordinate(surfaceX: point.x, surfaceY: point.y)
        var location = GhosttyPoint()
        location.tag = GHOSTTY_POINT_TAG_VIEWPORT
        location.value.coordinate = GhosttyPointCoordinate(x: cell.col, y: UInt32(cell.row))

        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(terminal, location, &ref) == GHOSTTY_SUCCESS else {
            return nil
        }
        return ref
    }

    /// Nil clears. The terminal copies the selection and converts it to
    /// tracked state, which is what makes it survive the next byte of output.
    private static func install(_ selection: GhosttySelection?, on terminal: GhosttyTerminal) {
        if var selection {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        } else {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        }
    }

    private static func geometry(_ size: RendererSize) -> GhosttySelectionGestureGeometry {
        GhosttySelectionGestureGeometry(
            columns: UInt32(max(1, size.grid.columns)),
            cell_width: max(1, size.cell.width),
            padding_left: size.padding.left,
            screen_height: max(1, size.screen.height))
    }
}
