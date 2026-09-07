//  SearchSession.swift
//  The find bar's state, and the loop that drives libghostty's search.
//
//  `search.h` splits the work into steps the caller drives, so that the caller
//  decides what a frame may cost. The decision belongs here, because this is
//  the only thing that knows a find bar is open: while it is, this pumps the
//  search on the main actor; when it closes, the pumping stops and the needle
//  goes with it, so a terminal with no find bar over it costs exactly what it
//  cost before this file existed.
//
//  Two cadences, because a search has two phases. Until it reports complete
//  there is scrollback left to look through and the loop runs at frame rate,
//  which is what turns a hundred thousand lines into more frames rather than
//  one long one. After that the loop still runs — feeding is the only way the
//  search hears about new output or a moved viewport — but slowly, because all
//  it is doing then is following.
//
//  Per terminal rather than per pane, and that is not a compromise: the search
//  is bound to the terminal's own screens, so two views of one terminal are
//  two views of one search.

import AppKit
import Observation

@MainActor
@Observable
final class SearchSession {
    /// Whether the find bar is on screen.
    private(set) var isOpen = false

    /// What the user typed. Setting it restarts the search — except when it is
    /// the query already in force, which libghostty answers by keeping the
    /// results it has.
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            engine.setSearchQuery(query)
            refresh()
        }
    }

    /// Bumped whenever something asks for the field back.
    ///
    /// ⌘F with the bar already open is the case: the bar is up, but the click
    /// that put the cursor in the terminal took the keyboard with it, and
    /// without this the chord would do nothing at all.
    private(set) var focusRequests = 0

    /// Matches found so far. Still growing while `isSearching`.
    private(set) var total = 0
    /// One-based position of the selected match, for "3 of 12". Nil when
    /// nothing is selected, which is what an empty or fruitless query looks
    /// like.
    private(set) var position: Int?
    /// True while there is scrollback still to look through.
    private(set) var isSearching = false

    /// The matches on screen, in the surface's own coordinates, for the bar to
    /// dodge. Empty whenever the surface is not on screen to measure against.
    private(set) var matchRects: [CGRect] = []

    private let engine: TerminalEngine

    /// The surface these matches are measured in. Weak, and rebound by the
    /// coordinator whenever a pane moves in the view tree: the engine outlives
    /// any one view of it, and a split or a zoom builds a new surface over the
    /// same terminal.
    private weak var surface: TerminalSurfaceView?

    private var pump: Task<Void, Never>?

    /// While the search is still reading scrollback, roughly a frame at 60 Hz.
    private static let workingInterval = Duration.milliseconds(16)
    /// Once it has caught up. Enough to follow live output and scrolling
    /// without spinning the main actor for a bar that is only being read.
    private static let followingInterval = Duration.milliseconds(100)

    init(engine: TerminalEngine) {
        self.engine = engine
    }

    /// Point this session at the surface its matches are drawn in.
    func bind(surface: TerminalSurfaceView?) {
        self.surface = surface
    }

    // MARK: - Opening and closing

    /// Show the find bar. Reopening keeps the last query, which is what every
    /// find bar does and what makes ⌘F ⌘F ⌘G worth typing.
    func open() {
        focusRequests += 1
        guard !isOpen else { return }
        isOpen = true
        if !query.isEmpty { engine.setSearchQuery(query) }
        start()
        refresh()
    }

    /// Hide the find bar and drop the search.
    ///
    /// The needle goes rather than being kept warm: holding one means every
    /// feed keeps rescanning for a query nobody is looking at, and the engine
    /// would go on forcing a repaint each time a match scrolled past.
    func close() {
        guard isOpen else { return }
        isOpen = false
        pump?.cancel()
        pump = nil
        engine.endSearch()
        total = 0
        position = nil
        isSearching = false
        matchRects = []
        lastSpans = []
    }

    // MARK: - Moving between matches

    /// The next match, toward older content, wrapping past the oldest.
    func selectNext() {
        guard isOpen, !query.isEmpty else { return }
        engine.selectNextMatch()
        refresh()
    }

    /// The previous match, toward newer content, wrapping past the newest.
    func selectPrevious() {
        guard isOpen, !query.isEmpty else { return }
        engine.selectPreviousMatch()
        refresh()
    }

    /// Whether stepping between matches would do anything, for the menu items
    /// that offer it.
    var canStep: Bool { isOpen && total > 0 }

    // MARK: - The loop

    private func start() {
        pump?.cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isOpen else { return }
                let interval =
                    self.isSearching ? Self.workingInterval : Self.followingInterval
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    /// The spans behind `matchRects`, kept so a frame where nothing moved does
    /// not force a repaint of the whole grid.
    private var lastSpans: [SearchMatchSpan] = []

    /// One step: catch the search up, then read what it now says.
    ///
    /// Every store below is guarded on the value actually changing. An
    /// `@Observable` property notifies on assignment rather than on
    /// difference, so writing the same count back ten times a second would
    /// rebuild the pane ten times a second for a bar that is only being read.
    private func refresh() {
        guard isOpen else { return }

        var progress = query.isEmpty ? SearchProgress.idle : engine.pumpSearch()

        // Land on a match without waiting for Enter — a find bar reporting
        // "12" and highlighting nothing in particular has answered a question
        // nobody asked. But not while the search is still reading scrollback:
        // selecting catches the search up with the terminal first, and that is
        // the one call here that could take a noticeable amount of time on a
        // large history. Once it reports complete, catching up is free.
        if progress.isComplete, progress.selected == nil, progress.total > 0 {
            engine.selectNextMatch()
            progress = engine.searchProgress
        }

        if total != progress.total { total = progress.total }
        // libghostty indexes matches newest-first from zero; a find bar counts
        // from one.
        let found = progress.selected.map { $0 + 1 }
        if position != found { position = found }
        let working = !progress.isComplete
        if isSearching != working { isSearching = working }

        let spans = query.isEmpty ? [] : engine.searchViewportSpans()
        let rects = surface?.rects(for: spans) ?? []
        if matchRects != rects { matchRects = rects }
        if spans != lastSpans {
            lastSpans = spans
            // The renderer is looking at the same terminal and will find the
            // same change, but it may be asleep: the display link pauses after
            // a second of quiet, and a terminal sitting idle while its find bar
            // is typed into is exactly that.
            engine.markHighlightsDirty()
        }
    }
}
