//  TerminalSearch.swift
//  libghostty's incremental search, bound to the engine's terminal.
//
//  `search.h` is designed so that searching a large scrollback never blocks a
//  frame, and the whole design is in who drives what:
//
//    * `tick` makes bounded progress on data the search has already copied. It
//      never touches the terminal.
//    * `feed` reads the terminal to pick up changes and hand the scrollback
//      searcher its next chunk. It needs exclusive terminal access, and it is
//      the *only* way the search learns the terminal moved.
//
//  So the lock discipline here is the same one `TerminalEngine+Selection`
//  documents, and for the same reason: everything below that touches the
//  terminal is called with the engine's lock held, from `TerminalEngine`'s own
//  search API. Nothing here takes a lock itself.
//
//  Matches come back as `GhosttySelection` snapshots of *untracked* grid refs,
//  which stop being valid at the next mutating call on the terminal. That is
//  why `viewportSpans` reads them and converts them to viewport cells in one
//  breath, under the lock, rather than handing anything raw upwards.

import Foundation
import GhosttyVt

/// One match, or the part of one that falls on a row, in viewport cells.
///
/// Row-local and inclusive, which is what the renderer paints from and what
/// the find bar measures its own dodge against.
struct SearchMatchSpan: Equatable {
    var row: Int
    var start: UInt16
    var end: UInt16
    /// The match "next" and "previous" are currently sitting on.
    var isSelected: Bool
}

/// What a find bar shows: "k of n", and whether n is still growing.
struct SearchProgress: Equatable {
    var total: Int = 0
    /// Zero-based index of the selected match, newest first. Nil when nothing
    /// is selected — before the first Enter, and whenever there are no matches.
    var selected: Int?
    /// False while there is scrollback still to look through.
    var isComplete: Bool = true

    static let idle = SearchProgress()
}

/// The search handle, and the buffers reading it reuses.
///
/// Not `Sendable` and not internally synchronized: the engine owns one of
/// these and serializes every call on it, which is what `search.h` asks for.
final class TerminalSearch {
    private var handle: GhosttySearch?

    /// What we are looking for, kept here so a terminal swapped in by `adopt`
    /// can be given the same query without the UI having to notice.
    private(set) var needle: String = ""

    /// Reused across reads so a frame's worth of matches allocates nothing
    /// once the buffer has grown to fit.
    private var matchBuffer: [GhosttySelection] = []

    /// How much `tick` work one pump is allowed. Bounded so a hundred thousand
    /// lines of scrollback degrade into more frames rather than one long one.
    private static let ticksPerPump = 8

    // MARK: - Lifetime

    /// Bind to `terminal`, replacing whatever was bound before.
    ///
    /// Call with the engine's lock held, and with `terminal` the one the engine
    /// now owns. A search cannot be rebound, so this makes a new one — and
    /// re-applies the needle, because an attach that replaces the terminal
    /// underneath an open find bar should not silently empty it.
    func rebind(to terminal: GhosttyTerminal?) {
        // Against the *old* terminal, which is why this cannot wait for
        // `deinit`: freeing a search releases tracked state it holds inside the
        // terminal it was created with.
        if let handle { ghostty_search_free(handle) }
        handle = nil

        guard let terminal else { return }
        var created: GhosttySearch?
        guard ghostty_search_new(nil, &created, terminal) == GHOSTTY_SUCCESS else { return }
        handle = created
        applyNeedle()
    }

    /// Release the search.
    ///
    /// Takes no terminal, unlike the selection gesture's teardown, because
    /// `ghostty_search_free` reaches the bound terminal itself — but it still
    /// has to run *before* that terminal is freed. The two can be freed in
    /// either order and `search.h` is explicit about it; doing it in this one
    /// hands the tracked state back instead of leaving it for the terminal's
    /// own teardown, and keeps the call serialized with everything else that
    /// touches the terminal.
    func free() {
        if let handle { ghostty_search_free(handle) }
        handle = nil
    }

    // MARK: - The query

    /// Set what to look for. Empty returns the search to idle.
    ///
    /// Setting the needle to the one already in force is free: libghostty
    /// keeps the existing results rather than restarting, so a find bar may
    /// resubmit as often as it likes.
    func setNeedle(_ text: String) {
        needle = text
        applyNeedle()
    }

    private func applyNeedle() {
        guard let handle else { return }
        guard !needle.isEmpty else {
            _ = ghostty_search_set(handle, GHOSTTY_SEARCH_OPT_NEEDLE, nil)
            return
        }
        let bytes = Array(needle.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            var string = GhosttyString(ptr: buffer.baseAddress, len: buffer.count)
            _ = ghostty_search_set(handle, GHOSTTY_SEARCH_OPT_NEEDLE, &string)
        }
    }

    // MARK: - Driving it

    /// Catch up with the terminal, then make a bounded amount of progress.
    ///
    /// One feed and up to `ticksPerPump` ticks. Both are bounded by libghostty,
    /// so this is the unit of work a caller can afford to repeat every frame
    /// without ever holding the terminal long enough to stall the reader.
    @discardableResult
    func pump() -> SearchProgress {
        guard let handle, !needle.isEmpty else { return .idle }
        _ = ghostty_search_feed(handle)

        var status = GHOSTTY_SEARCH_STATUS_COMPLETE
        for _ in 0..<Self.ticksPerPump {
            guard ghostty_search_tick(handle, &status) == GHOSTTY_SUCCESS else { break }
            guard status == GHOSTTY_SEARCH_STATUS_RUNNING else { break }
        }
        return progress
    }

    /// Counts and status, without touching the terminal.
    var progress: SearchProgress {
        guard let handle, !needle.isEmpty else { return .idle }

        var status = GHOSTTY_SEARCH_STATUS_COMPLETE
        var total = 0
        _ = ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_STATUS, &status)
        _ = ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)

        // NO_VALUE, not an error: nothing is selected until the first Enter.
        var index = 0
        let selected =
            ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index)
                == GHOSTTY_SUCCESS ? Int(index) : nil

        return SearchProgress(
            total: Int(total),
            selected: selected,
            isComplete: status == GHOSTTY_SEARCH_STATUS_COMPLETE)
    }

    /// Move to the next match, toward older content, wrapping at the oldest.
    ///
    /// Returns whether anything was selected. libghostty catches the search up
    /// with the terminal first and scrolls the viewport to the match if it is
    /// not already on screen, so this is safe to call at any point between
    /// pumps.
    @discardableResult
    func selectNext() -> Bool {
        guard let handle else { return false }
        return ghostty_search_set(handle, GHOSTTY_SEARCH_OPT_SELECT_NEXT, nil) == GHOSTTY_SUCCESS
    }

    /// Move to the previous match, toward newer content, wrapping at the newest.
    @discardableResult
    func selectPrevious() -> Bool {
        guard let handle else { return false }
        return ghostty_search_set(handle, GHOSTTY_SEARCH_OPT_SELECT_PREV, nil) == GHOSTTY_SUCCESS
    }

    // MARK: - Matches on screen

    /// The matches covering the viewport, as row-local cell ranges.
    ///
    /// The C API hands out matches as selections over grid references, and
    /// stops there — Ghostty's `RenderState.Highlight` is not exposed — so
    /// turning them into the spans a renderer paints is ours to write. That is
    /// this function, and it is the only real work in #16 beyond wiring.
    ///
    /// Matches are found a page at a time, so libghostty's list can include
    /// matches just outside the viewport when they share a page with it.
    /// Converting to viewport coordinates clips that naturally: a reference
    /// that has scrolled out of the visible area has no viewport coordinate at
    /// all, and comes back as `GHOSTTY_NO_VALUE`.
    func viewportSpans(
        terminal: GhosttyTerminal, columns: UInt16, rows: UInt16, into out: inout [SearchMatchSpan]
    ) {
        out.removeAll(keepingCapacity: true)
        guard let handle, !needle.isEmpty else { return }

        let count = readMatches(handle, into: &matchBuffer)
        guard count > 0 else { return }

        // The match the find bar is on, in the same space, so the renderer can
        // paint it differently without comparing grid-ref internals.
        let selected = selectedRange(handle, terminal: terminal)

        for index in 0..<count {
            guard
                let range = viewportRange(matchBuffer[index], terminal: terminal, rows: rows)
            else { continue }
            append(range, columns: columns, isSelected: range == selected, into: &out)
        }
    }

    /// Read the viewport match list into `buffer`, growing it if it is short.
    ///
    /// Returns how many entries are valid. The query-then-read dance is the
    /// buffer convention every list-valued libghostty call uses: a NULL pointer
    /// with zero capacity reports what is needed rather than writing anything.
    private func readMatches(
        _ handle: GhosttySearch, into buffer: inout [GhosttySelection]
    ) -> Int {
        var sizing = GhosttySelectionBuffer(ptr: nil, cap: 0, len: 0)
        let sized = ghostty_search_get(
            handle, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &sizing)
        // SUCCESS with an empty buffer means there is nothing to draw;
        // OUT_OF_SPACE means `len` is the capacity to come back with.
        guard sized == GHOSTTY_OUT_OF_SPACE, sizing.len > 0 else { return 0 }

        let required = Int(sizing.len)
        if buffer.count < required {
            buffer = [GhosttySelection](repeating: GhosttySelection(), count: required)
        }

        var written = 0
        buffer.withUnsafeMutableBufferPointer { storage in
            var request = GhosttySelectionBuffer(
                ptr: storage.baseAddress, cap: storage.count, len: 0)
            guard
                ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &request)
                    == GHOSTTY_SUCCESS
            else { return }
            written = Int(request.len)
        }
        return min(written, buffer.count)
    }

    /// The selected match in viewport coordinates, if it is on screen at all.
    private func selectedRange(
        _ handle: GhosttySearch, terminal: GhosttyTerminal
    ) -> ViewportRange? {
        var match = GhosttySelection()
        match.size = MemoryLayout<GhosttySelection>.size
        guard
            ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &match)
                == GHOSTTY_SUCCESS
        else { return nil }
        // No row bound: the selected match is compared against matches that
        // already passed one, and clamping it here would make an off-screen
        // match compare equal to an on-screen one on the same row.
        return viewportRange(match, terminal: terminal, rows: nil)
    }

    /// A match reduced to its two viewport endpoints, in reading order.
    private struct ViewportRange: Equatable {
        var startRow: Int
        var startColumn: UInt16
        var endRow: Int
        var endColumn: UInt16
    }

    /// Convert both endpoints of `match` to viewport cells.
    ///
    /// Nil when either endpoint has no viewport coordinate — a match wholly or
    /// partly in the scrollback above the screen — which is the clipping the
    /// header describes. Endpoints may be stored in either order, so they are
    /// put back into reading order here rather than at every call site.
    private func viewportRange(
        _ match: GhosttySelection, terminal: GhosttyTerminal, rows: UInt16?
    ) -> ViewportRange? {
        var startRef = match.start
        var endRef = match.end
        var start = GhosttyPointCoordinate()
        var end = GhosttyPointCoordinate()
        guard
            ghostty_terminal_point_from_grid_ref(
                terminal, &startRef, GHOSTTY_POINT_TAG_VIEWPORT, &start) == GHOSTTY_SUCCESS,
            ghostty_terminal_point_from_grid_ref(
                terminal, &endRef, GHOSTTY_POINT_TAG_VIEWPORT, &end) == GHOSTTY_SUCCESS
        else { return nil }

        if let rows, start.y >= UInt32(rows) || end.y >= UInt32(rows) { return nil }

        let ordered = (start.y, start.x) <= (end.y, end.x)
        let first = ordered ? start : end
        let last = ordered ? end : start
        return ViewportRange(
            startRow: Int(first.y), startColumn: first.x,
            endRow: Int(last.y), endColumn: last.x)
    }

    /// Break a range across the rows it covers.
    ///
    /// A needle that crosses a line boundary matches over two rows, and the
    /// renderer works in row-local spans, so the middle rows are full width and
    /// only the ends are partial.
    private func append(
        _ range: ViewportRange, columns: UInt16, isSelected: Bool,
        into out: inout [SearchMatchSpan]
    ) {
        guard columns > 0 else { return }
        let lastColumn = columns - 1
        for row in range.startRow...range.endRow {
            let start = row == range.startRow ? min(range.startColumn, lastColumn) : 0
            let end = row == range.endRow ? min(range.endColumn, lastColumn) : lastColumn
            guard start <= end else { continue }
            out.append(
                SearchMatchSpan(row: row, start: start, end: end, isSelected: isSelected))
        }
    }
}
