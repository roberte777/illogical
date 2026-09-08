//  TerminalEngine+Search.swift
//  Search over the client's own terminal, including its scrollback.
//
//  Every function here runs inside `withTerminal`, which holds the engine's
//  lock — the same discipline `TerminalEngine+Selection` is written to, and
//  necessary for the same reason. `ghostty_search_feed` reads the terminal
//  while the connection's reader thread is writing to it, and the matches it
//  produces are untracked grid references that stop being valid at the next
//  byte of output. Deriving one and using it are one operation or they are a
//  use-after-free.
//
//  What is *not* here is the tick loop. `search.h` splits the work so that the
//  caller decides how much a frame may cost, and that decision belongs to the
//  thing that knows a find bar is open: `SearchSession` drives `pumpSearch`
//  off the main actor while the bar is on screen, and stops the moment it
//  closes.

import Foundation
import GhosttyVt

extension TerminalEngine {
    /// Set what to look for. Empty returns the search to idle and drops every
    /// highlight.
    ///
    /// Setting the query already in force keeps the results libghostty has
    /// found so far, so a find bar may resubmit as often as it likes.
    func setSearchQuery(_ query: String) {
        _ = withTerminal { _ -> Bool? in
            search.setNeedle(query)
            return true
        }
        invalidate()
    }

    /// Catch the search up with the terminal and make bounded progress.
    ///
    /// One feed and a handful of ticks, all bounded by libghostty. Cheap
    /// enough to call every frame the find bar is open, which is what keeps
    /// matches following live output and a moving viewport.
    @discardableResult
    func pumpSearch() -> SearchProgress {
        withTerminal { _ -> SearchProgress? in
            search.pump()
        } ?? .idle
    }

    /// Counts and status, for "k of n".
    var searchProgress: SearchProgress {
        withTerminal { _ -> SearchProgress? in
            search.progress
        } ?? .idle
    }

    /// Move to the next match, toward older content, wrapping at the oldest.
    ///
    /// The viewport follows: libghostty scrolls to the newly selected match
    /// when it is not already on screen. That moves every row on screen
    /// without changing a cell, which is exactly what `invalidate` exists for.
    @discardableResult
    func selectNextMatch() -> Bool {
        let moved =
            withTerminal { _ -> Bool? in
                search.selectNext()
            } ?? false
        invalidate()
        return moved
    }

    /// Move to the previous match, toward newer content, wrapping at the newest.
    @discardableResult
    func selectPreviousMatch() -> Bool {
        let moved =
            withTerminal { _ -> Bool? in
                search.selectPrevious()
            } ?? false
        invalidate()
        return moved
    }

    /// The matches on the viewport, as row-local cell ranges.
    ///
    /// Read fresh rather than cached, per `search.h`: the safe way to follow a
    /// match across terminal changes is to re-read it, and the conversion to
    /// viewport cells has to happen under the same lock as the read.
    func searchViewportSpans() -> [SearchMatchSpan] {
        var spans: [SearchMatchSpan] = []
        _ = withTerminal { terminal -> Bool? in
            search.viewportSpans(
                terminal: terminal, columns: cols, rows: rows, into: &spans)
            return true
        }
        return spans
    }

    /// The find bar closed: drop the needle, the results, and the highlights.
    func endSearch() {
        setSearchQuery("")
    }
}
