//  ScrollbackRestoreTests.swift
//  Does the server's scrollback actually survive an attach?
//
//  Scrolling is worth nothing if there is no history to scroll into, and the
//  attach path has a lot of moving parts: the snapshot is encoded on the
//  server, framed into chunks, reassembled, then decoded in two phases with
//  history prepended a page at a time. This exercises the client's half of
//  that against a real libghostty snapshot.

import GhosttyVt
import XCTest

final class ScrollbackRestoreTests: XCTestCase {
    /// Build a terminal with `lines` of scrollback above a `rows`-tall screen.
    private func makeTerminal(cols: UInt16, rows: UInt16, lines: Int) throws -> GhosttyTerminal {
        var handle: GhosttyTerminal?
        try check("ghostty_terminal_new") { ghostty_terminal_new(nil, &handle, cols, rows) }
        let terminal = try XCTUnwrap(handle)

        var text = ""
        for i in 0..<lines { text += "line \(i)\r\n" }
        var bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            ghostty_terminal_vt_write(terminal, buf.baseAddress, buf.count)
        }
        return terminal
    }

    private func scrollbar(_ terminal: GhosttyTerminal) -> GhosttyTerminalScrollbar {
        var bar = GhosttyTerminalScrollbar()
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        return bar
    }

    /// Sanity: writing more lines than fit produces scrollback at all.
    func testWritingBuildsScrollback() throws {
        let terminal = try makeTerminal(cols: 40, rows: 10, lines: 500)
        defer { ghostty_terminal_free(terminal) }

        let bar = scrollbar(terminal)
        XCTAssertEqual(bar.len, 10, "the viewport is the screen height")
        XCTAssertGreaterThan(bar.total, 400, "expected ~500 rows of scrollable area")
        XCTAssertEqual(
            bar.offset, bar.total - bar.len, "a fresh terminal sits at the bottom")
    }

    /// The two-phase restore: `ready` gives a renderable screen immediately,
    /// then history is prepended a page at a time.
    ///
    /// The line count has to be large enough to spill past one libghostty
    /// page. Below that the whole terminal, scrollback included, is written
    /// before the READY marker and there is no history phase at all — which
    /// is the format working as intended, not a bug.
    func testHistorySurvivesASnapshotRoundTrip() throws {
        let source = try makeTerminal(cols: 80, rows: 24, lines: 40_000)
        defer { ghostty_terminal_free(source) }
        let sourceBar = scrollbar(source)

        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        try check("ghostty_snapshot_encode_alloc") {
            ghostty_snapshot_encode_alloc(source, nil, &ptr, &len)
        }
        let raw = try XCTUnwrap(ptr)
        defer { ghostty_free(nil, raw, len) }
        XCTAssertGreaterThan(len, 0)

        let restore = try SnapshotRestore(snapshot: Data(bytes: raw, count: len))
        let restored = try restore.ready()
        defer { ghostty_terminal_free(restored) }

        // Phase 1: the screen is renderable but the history has not landed.
        let afterReady = scrollbar(restored)
        XCTAssertEqual(afterReady.len, 24, "the screen came back")

        // Phase 2: prepend history until FINISH.
        var pages = 0
        while try restore.restoreNextHistoryPage() {
            pages += 1
            XCTAssertLessThan(pages, 10_000, "history restore did not terminate")
        }
        XCTAssertGreaterThan(pages, 0, "no history pages were restored")

        let afterHistory = scrollbar(restored)
        XCTAssertEqual(
            afterHistory.total, sourceBar.total,
            "restored scrollback should match the source")
        XCTAssertGreaterThan(
            afterHistory.total, afterReady.total,
            "history should have grown the scrollable area")
    }

    /// The restored terminal's history holds the right text, not just the
    /// right number of rows.
    func testRestoredHistoryHasTheOriginalText() throws {
        let source = try makeTerminal(cols: 40, rows: 10, lines: 200)
        defer { ghostty_terminal_free(source) }

        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        try check("ghostty_snapshot_encode_alloc") {
            ghostty_snapshot_encode_alloc(source, nil, &ptr, &len)
        }
        let raw = try XCTUnwrap(ptr)
        defer { ghostty_free(nil, raw, len) }

        let restore = try SnapshotRestore(snapshot: Data(bytes: raw, count: len))
        let restored = try restore.ready()
        defer { ghostty_terminal_free(restored) }
        while try restore.restoreNextHistoryPage() {}

        // Scroll to the very top and read the first row back through the
        // render state, which is the same path the renderer uses.
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_TOP
        ghostty_terminal_scroll_viewport(restored, behavior)

        let engineText = try firstRowText(of: restored)
        XCTAssertEqual(
            engineText.trimmingCharacters(in: .whitespaces), "line 0",
            "the oldest scrollback row should be the first line written")
    }

    /// Read row 0 of the viewport as a string, through the render state.
    private func firstRowText(of terminal: GhosttyTerminal) throws -> String {
        var state: GhosttyRenderState?
        try check("ghostty_render_state_new") { ghostty_render_state_new(nil, &state) }
        let renderState = try XCTUnwrap(state)
        defer { ghostty_render_state_free(renderState) }
        try check("ghostty_render_state_update") {
            ghostty_render_state_update(renderState, terminal)
        }

        var iterator: GhosttyRenderStateRowIterator?
        try check("row_iterator_new") {
            ghostty_render_state_row_iterator_new(nil, &iterator)
        }
        defer { ghostty_render_state_row_iterator_free(iterator) }
        try check("get row iterator") {
            ghostty_render_state_get(
                renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator)
        }

        var cells: GhosttyRenderStateRowCells?
        try check("row_cells_new") { ghostty_render_state_row_cells_new(nil, &cells) }
        defer { ghostty_render_state_row_cells_free(cells) }

        guard ghostty_render_state_row_iterator_next(iterator) else { return "" }
        guard
            ghostty_render_state_row_get(
                iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS
        else { return "" }

        var text = ""
        var buf = [UInt8](repeating: 0, count: 64)
        while ghostty_render_state_row_cells_next(cells) {
            let piece = buf.withUnsafeMutableBufferPointer { b -> String in
                var out = GhosttyBuffer()
                out.ptr = b.baseAddress
                out.cap = b.count
                out.len = 0
                guard
                    ghostty_render_state_row_cells_get(
                        cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &out)
                        == GHOSTTY_SUCCESS, out.len > 0
                else { return "" }
                return String(
                    decoding: UnsafeBufferPointer(start: b.baseAddress, count: out.len),
                    as: UTF8.self)
            }
            text += piece.isEmpty ? " " : piece
        }
        return text
    }
}
