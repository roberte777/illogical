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
//
//  One renderer, though, and that is not a detail. The render state is per
//  *terminal*: `begin_update` "consumes terminal/screen dirty state", so a
//  second renderer pulling frames from this engine takes the changed rows the
//  first one needed and leaves it painting a screen from before they arrived.
//  `bind` is what enforces it — see `TerminalRenderSink`.

import Foundation
import GhosttyVt

final class TerminalEngine: @unchecked Sendable {
    private var terminal: GhosttyTerminal?
    private var renderState: GhosttyRenderState?
    private let lock = NSLock()

    /// Serializes `updateSnapshot` against itself.
    ///
    /// `lock` is not enough and is not meant to be: it covers the terminal, and
    /// is deliberately dropped for the whole extraction so the reader thread
    /// can keep writing. What the extraction then reads — the render state, the
    /// row iterator, the row cells — is engine-owned and single-threaded by
    /// assumption, and the assumption holds only while one renderer is pulling
    /// frames. `bind` sees to that, but not instantly: the displaced surface's
    /// render thread can be *inside* this call when its replacement binds, and
    /// two threads sharing one row iterator is a garbled row, not a late one.
    ///
    /// Uncontended in every steady state, which is what makes it cheap enough
    /// to hold across the whole call.
    private let frameLock = NSLock()

    /// Selection gesture state. Owned here because it holds *tracked*
    /// references into `terminal`, which have to be released against that
    /// terminal before it is freed — see `adopt`.
    let selectionGesture = SelectionGesture()

    /// Incremental search over this terminal and its scrollback.
    ///
    /// Owned here for the same reason the gesture is: it registers state
    /// *inside* the terminal it was created with, so it has to be rebound when
    /// `adopt` swaps that terminal and released before either is freed. Not
    /// `private` only because `TerminalEngine+Search` is the API over it —
    /// every method on it wants `lock` held, and that extension is where that
    /// happens.
    let search = TerminalSearch()

    /// Reused across frames so extraction allocates nothing.
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var graphemeScratch = [UInt32](repeating: 0, count: 64)

    /// Search matches on the viewport, as of this frame and the last.
    ///
    /// Render-thread only, like `rowIterator`: `updateSnapshot` fills the first
    /// under the lock and `extractRow` reads it after that lock is released,
    /// and nothing else touches either. The previous frame's copy is kept so a
    /// frame where the matches did not move costs a comparison instead of a
    /// full repaint — highlights change no cell, so libghostty's own dirty
    /// flags cannot see them.
    private var searchSpans: [SearchMatchSpan] = []
    private var lastSearchSpans: [SearchMatchSpan] = []

    private(set) var cols: UInt16
    private(set) var rows: UInt16

    /// Set when the whole screen must be rebuilt regardless of what
    /// libghostty's per-row dirty flags say. Guarded by `lock`.
    private var forceFullRebuild = false

    /// Rows of scrollback the attach snapshot declared and has not delivered.
    ///
    /// Guarded by `lock` rather than made atomic, because the history restore
    /// already decrements it under that lock in the same breath as the decode
    /// that earned the decrement, and `scrollbar` already holds it to read the
    /// rows this is added to. An atomic would let those two drift apart for a
    /// frame and buy nothing.
    private var pendingHistoryRows: UInt64 = 0

    /// Set when bytes have been applied and a frame is owed. Read from the
    /// display link every tick, so it is an atomic rather than lock-guarded:
    /// an idle terminal must not cost a lock acquisition 120 times a second.
    private let dirtyFlag = Atomic(true)

    /// Set by `adopt`, taken by the first frame that draws the result. The
    /// launch budget times `snapshot_ready` to that frame, not to the blank
    /// surface already on screen.
    private let adoptedFlag = Atomic(false)

    /// Called when the engine goes from clean to dirty, so the view can
    /// restart a paused display link. An idle terminal should cost nothing,
    /// which means the display link has to actually stop.
    ///
    /// Read from the reader thread and written from the main actor, the same
    /// unguarded discipline it has always had: a torn read of a closure slot
    /// costs at worst one missed wake on the very frame a surface is being
    /// swapped, and taking `lock` here would deadlock — `markDirty` is called
    /// from inside the write path that already holds it.
    private var wake: (@Sendable () -> Void)?

    /// The surface `wake` belongs to.
    ///
    /// One engine can be held by *two* surfaces at once, and that is the whole
    /// reason this is not a plain settable property. Anything that changes a
    /// tab's split tree — a pane arriving, a pane closing, a zoom — moves the
    /// surviving pane to a new position in the view tree, so SwiftUI builds it
    /// a fresh `TerminalSurfaceView` while keeping the outgoing one alive for
    /// the length of the transition. Both are bound to this engine, and the
    /// old one's teardown would otherwise clear the callback the *live* one had
    /// already installed. The display link then pauses after a second of quiet
    /// with nothing left to restart it, and the pane silently stops repainting
    /// until it is clicked or typed into.
    ///
    /// Weak: the engine outlives any one view of it, and a surface holds the
    /// engine strongly.
    ///
    /// Main-actor only. `markDirty` reads `wake` and never this.
    private weak var boundView: AnyObject?

    /// The renderer `boundView` draws with, so the one it displaced can be
    /// stopped.
    ///
    /// Weak, and for the same reason `boundView` is: a surface holds its
    /// renderer, and both outlive nothing here.
    ///
    /// Main-actor only.
    private weak var boundSink: TerminalRenderSink?

    /// Bind `view` to this engine, displacing whatever was bound before.
    ///
    /// The displaced surface's renderer is stopped rather than merely ignored.
    /// Both surfaces are on screen for the length of the transition, both have
    /// a render thread, and both would otherwise call `updateSnapshot` — which
    /// drives one render state, one row iterator and one set of dirty flags.
    /// The frames the displaced one takes are frames the live one never sees:
    /// its rows stay as they were before the split until something forces a
    /// full rebuild, which in practice meant clicking the pane.
    @MainActor
    func bind(
        _ view: AnyObject,
        sink: TerminalRenderSink? = nil,
        wake: @escaping @Sendable () -> Void
    ) {
        if boundSink !== sink { boundSink?.setActive(false) }
        boundView = view
        boundSink = sink
        self.wake = wake
        sink?.setActive(true)
        // Whatever the outgoing renderer consumed before the handover is dirty
        // state the incoming one will never be told about, so it starts from a
        // whole screen rather than from the rows that happen to be marked.
        invalidate()
    }

    /// Unbind `view`. A no-op unless `view` is still the bound one, which is
    /// what stops a displaced surface taking the live callback with it.
    @MainActor
    func unbind(_ view: AnyObject) {
        guard boundView === view else { return }
        boundSink?.setActive(false)
        boundView = nil
        boundSink = nil
        wake = nil
    }

    /// Whether `view` is the surface this engine currently answers to.
    ///
    /// False for one that has been displaced but is still on screen fading
    /// out — which is exactly the surface that must not resize the PTY.
    @MainActor
    func isBound(_ view: AnyObject) -> Bool {
        boundView === view
    }

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

        // Cheap, and it reads nothing: creating a search only registers it with
        // the terminal so the two can be freed in either order. It stays idle
        // until a find bar gives it a needle.
        search.rebind(to: term)

        applyThemeLocked()
    }

    /// The default colours a cell with none of its own is drawn in, and the
    /// palette an SGR index is looked up in.
    ///
    /// Read from the config once per terminal, which includes the one built by
    /// `adopt` — a snapshot decodes with libghostty's own white-on-black
    /// defaults, so a terminal that arrived over the wire has to be told the
    /// theme just as a fresh one does.
    ///
    /// The cursor is set only when the config named a fixed colour for it.
    /// Left unset otherwise, and deliberately: the render state reports the
    /// *effective* cursor colour, so a default written here would be
    /// indistinguishable from a program's OSC 12 and would take precedence
    /// over `cursor-color = cell-foreground` in the renderer. Unset is what
    /// makes `snapshot.cursorColor` mean "the program asked for this one".
    private func applyThemeLocked() {
        guard let terminal else { return }
        let colors = TerminalColors.from(AppConfig.current)

        var background = colors.background
        var foreground = colors.foreground
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)

        if var cursor = colors.cursor {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor)
        } else {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil)
        }

        // Setting the palette keeps whatever OSC 4 has already changed, which
        // is what makes this safe to call on `adopt`: a program that recoloured
        // index 1 before we attached keeps its colour.
        var palette = colors.palette
        palette.withUnsafeMutableBufferPointer {
            _ = ghostty_terminal_set(
                terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, $0.baseAddress)
        }
    }

    deinit {
        // Before the terminal: the gesture's tracked references belong to it,
        // and so does the state the search registered inside it.
        selectionGesture.free(terminal: terminal)
        search.free()
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let renderState { ghostty_render_state_free(renderState) }
        if let terminal { ghostty_terminal_free(terminal) }
    }

    /// Replace our terminal with one decoded from a server snapshot.
    ///
    /// This is the attach path: the snapshot carries the screen the server
    /// already has, so we adopt it wholesale instead of replaying history.
    func adopt(terminal newTerminal: GhosttyTerminal) {
        // Its own size, not ours. The terminal in a snapshot is whatever size
        // the server's was, and ours may be a resize behind it -- a window
        // dragged while the connection was down attaches at the new size and
        // gets a snapshot to match, while `cols`/`rows` here still say what
        // they said before the outage.
        var cols: UInt16 = 0
        var rows: UInt16 = 0
        _ = ghostty_terminal_get(newTerminal, GHOSTTY_TERMINAL_DATA_COLS, &cols)
        _ = ghostty_terminal_get(newTerminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        lock.lock()
        if let terminal {
            // Tracked references into a terminal do not survive it, and neither
            // the gesture nor the search can find that out on its own. The
            // search is released rather than reset because it cannot be
            // rebound: `rebind` below makes a new one over the new terminal and
            // gives it the query the old one had, so a find bar open across an
            // attach keeps looking for the same thing.
            selectionGesture.reset(terminal: terminal)
            search.free()
            ghostty_terminal_free(terminal)
        }
        terminal = newTerminal
        search.rebind(to: newTerminal)
        self.cols = cols
        self.rows = rows
        // A new terminal has whatever history READY brought with it and no
        // more, so any count of what is still owed describes the terminal we
        // just freed. The caller declares the new one's immediately below.
        pendingHistoryRows = 0
        // A snapshot-decoded terminal carries libghostty's defaults, not ours.
        applyThemeLocked()
        lock.unlock()
        adoptedFlag.store(true)
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

    /// Run `body` with the engine's lock held.
    ///
    /// For mutations made through a handle the engine owns but did not
    /// perform itself — the snapshot decoder's history restore writes into
    /// the terminal it handed us, and the render thread reads that same
    /// terminal under this lock.
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Run `body` with the raw terminal handle held under the engine's lock.
    ///
    /// The input encoders need terminal state the client does not otherwise
    /// model — cursor-key mode, keypad mode, the Kitty keyboard flags, mouse
    /// tracking — and that state changes on the reader thread. Reading it and
    /// then encoding against it outside the lock would encode against modes
    /// the terminal has already left. Returns nil when there is no terminal,
    /// which happens between `init` and the first snapshot only if that
    /// snapshot fails to decode.
    func withTerminal<T>(_ body: (GhosttyTerminal) -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal else { return nil }
        return body(terminal)
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

    /// Force the next frame to rebuild every row, and ask for one.
    ///
    /// The same flag a viewport move sets, for the same reason: neither a
    /// selection nor a search match changes a cell, so libghostty's per-row
    /// dirty flags — which describe content, not what is on screen — do not
    /// describe them either. A surface handover is the third caller, and its
    /// reason is the opposite one: the rows *did* change, and the renderer that
    /// is about to draw them was not the one told about it.
    ///
    /// It also has to *wake* the render loop, which pauses after a second of
    /// quiet: a terminal sitting idle while its find bar is typed into would
    /// otherwise not draw the highlights at all.
    func invalidate() {
        lock.lock()
        forceFullRebuild = true
        lock.unlock()
        markDirty()
    }

    // MARK: - Viewport

    /// Where to move the viewport.
    enum ScrollTarget {
        case top
        case bottom
        /// Rows, negative for up.
        case delta(Int)
        /// Absolute row, in the same space as `ScrollbarState.offset` — which
        /// includes any rows still pending, so this round-trips with what the
        /// scrollbar reports rather than with the terminal's own row numbers.
        case row(UInt64)
    }

    /// The scrollable area, in rows.
    ///
    /// This is the *declared* area, not the delivered one: `total` and
    /// `offset` both count the rows an attach snapshot has promised and not
    /// yet sent, and `pending` says how many of them those are. The whole
    /// point is that they move together — as history lands, `pending` falls by
    /// exactly what `offset` gains, so a viewport parked in the scrollback
    /// keeps the same position on the bar instead of sliding down it while the
    /// extent grows underneath. See docs/CLIENT.md, "The loading state".
    struct ScrollbarState: Equatable {
        var total: UInt64 = 0
        var offset: UInt64 = 0
        var length: UInt64 = 0
        /// Undelivered rows, at the top of the area. Drawn distinctly, and
        /// not reachable by scrolling until they arrive.
        var pending: UInt64 = 0

        /// True when the viewport is somewhere above the live output.
        var isScrolledBack: Bool { offset + length < total }
        /// True when there is anything to scroll at all.
        var canScroll: Bool { total > length }
    }

    /// Move the viewport.
    ///
    /// Purely client-side: the server is never told, and two clients attached
    /// to one terminal scroll independently. That is deliberate — the tmux
    /// behaviour where one client's scroll moves everyone's window is a bug
    /// we are not reproducing (see docs/CLIENT.md).
    func scroll(_ target: ScrollTarget) {
        lock.lock()
        guard let terminal else {
            lock.unlock()
            return
        }

        var behavior = GhosttyTerminalScrollViewport()
        switch target {
        case .top:
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_TOP
        case .bottom:
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        case .delta(let rows):
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            // intptr_t on the C side.
            behavior.value.delta = rows
        case .row(let row):
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
            // Back out of the scrollbar's space into the terminal's. Rows the
            // snapshot still owes us are counted in the former and do not
            // exist in the latter, so a drag into the pending region lands at
            // the top of what has actually arrived — which is as far up as
            // there is anything to show.
            let pending = effectivePendingLocked(terminal)
            // size_t on the C side; the scrollbar reports UInt64.
            behavior.value.row = Int(clamping: row > pending ? row - pending : 0)
        }
        ghostty_terminal_scroll_viewport(terminal, behavior)

        // Moving the viewport changes every row on screen, and libghostty's
        // per-row dirty flags describe content rather than position. Without
        // this the next frame would rebuild nothing and the screen would not
        // move.
        forceFullRebuild = true
        lock.unlock()
        markDirty()
    }

    /// The current scrollable area. Cheap enough to read per scroll event.
    var scrollbar: ScrollbarState {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal else { return ScrollbarState() }
        var bar = GhosttyTerminalScrollbar()
        guard
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
                == GHOSTTY_SUCCESS
        else { return ScrollbarState() }

        // Pending rows sit above everything the terminal holds, so they extend
        // the area at the top: the total grows by them and every position
        // within it, the viewport's included, shifts down by the same amount.
        let pending = effectivePendingLocked(terminal)
        return ScrollbarState(
            total: bar.total + pending,
            offset: bar.offset + pending,
            length: bar.len,
            pending: pending)
    }

    // MARK: - Pending history

    /// Owed rows, as they apply to the screen currently on display.
    ///
    /// Undelivered history belongs to the primary screen, so a terminal
    /// sitting in a full-screen TUI reports none. The alternate screen has no
    /// scrollback of its own, and adding the primary's owed rows to its bar
    /// would invent a scrollable area where there is none. Nothing is
    /// forgotten by doing so: the count is still there when the program exits
    /// and the primary screen, with its history and whatever is still owed on
    /// it, comes back.
    private func effectivePendingLocked(_ terminal: GhosttyTerminal) -> UInt64 {
        guard pendingHistoryRows > 0 else { return 0 }
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        let known =
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
            == GHOSTTY_SUCCESS
        guard !known || screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY else { return 0 }
        return pendingHistoryRows
    }

    /// Declare how much scrollback the attach snapshot still owes us.
    ///
    /// Takes the snapshot's own extent — every row above the active area,
    /// which is what `SnapshotRestore.declaredHistoryRows` reports — and
    /// subtracts what READY already handed over. The snapshot counts the
    /// resident overlap it carries before READY in that extent, so passing the
    /// declared figure straight through would draw the rows we are already
    /// looking at as pending.
    ///
    /// Call after `adopt`, which clears whatever the previous terminal owed.
    func declarePendingHistory(rows declared: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal else { return }
        var bar = GhosttyTerminalScrollbar()
        guard
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
                == GHOSTTY_SUCCESS
        else { return }
        // Saturating, not because a viewport taller than its own scrollable
        // area is expected, but because the alternative is a trap: these are
        // unsigned, and Swift crashes rather than wrapping.
        let resident = bar.total > bar.len ? bar.total - bar.len : 0
        pendingHistoryRows = declared > resident ? declared - resident : 0
    }

    /// Account for a history page that has landed.
    ///
    /// **Call with the lock already held**, from inside the same `withLock` as
    /// the decode that produced these rows. The lock is not recursive, so this
    /// cannot take it — but that constraint is the correct one anyway: the
    /// rows and the drop in what is owed have to reach the renderer together
    /// or the knob moves by the difference.
    ///
    /// Counted down rather than recomputed from the terminal, because live
    /// output pushes rows into the same history and would otherwise be
    /// mistaken for scrollback arriving. Saturates at zero: the declared
    /// extent is advisory and the pages are what actually happened.
    func historyPageRestoredLocked(rows: Int) {
        guard rows > 0 else { return }
        let landed = UInt64(rows)
        pendingHistoryRows = pendingHistoryRows > landed ? pendingHistoryRows - landed : 0
    }

    /// Nothing more is coming: drop whatever is still owed.
    ///
    /// The end of a restore, however it ended. The declared extent is
    /// advisory, so a snapshot whose pages applied fewer rows than it promised
    /// would otherwise leave a sliver of the bar pending forever.
    func clearPendingHistory() {
        lock.lock()
        pendingHistoryRows = 0
        lock.unlock()
    }

    /// Whether the program has asked to receive mouse events.
    ///
    /// When it has, the wheel belongs to it and must not move our viewport —
    /// scrolling in `less` should scroll `less`, not slide our window over its
    /// output. We can't encode those events yet, so for now the wheel simply
    /// does nothing in that mode.
    var isMouseTracking: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal else { return false }
        var tracking = false
        guard
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
                == GHOSTTY_SUCCESS
        else { return false }
        return tracking
    }

    private func markDirty() {
        // Only wake on the clean -> dirty edge. A terminal spewing output
        // must not post a wakeup per write.
        if !dirtyFlag.exchange(true) {
            wake?()
        }
    }

    // MARK: - Render source

    var isDirty: Bool { dirtyFlag.load() }

    func consumeSnapshotAdopted() -> Bool { adoptedFlag.exchange(false) }

    /// Take a consistent view of the terminal into `snapshot`.
    ///
    /// The terminal lock is held for the `begin_update` call only. `frameLock`
    /// is held for all of it: everything read after `begin_update` belongs to
    /// the render state, and there is one of those.
    func updateSnapshot(into snapshot: TerminalSnapshot) -> Bool {
        guard let renderState, let rowIterator, let rowCells else { return false }

        frameLock.lock()
        defer { frameLock.unlock() }

        lock.lock()
        guard let terminal else {
            lock.unlock()
            return false
        }
        // Under the same lock as `begin_update`, and it has to be: a match is
        // an *untracked* grid reference, valid only until the next byte of
        // output, so reading the list and turning it into viewport cells is
        // one operation or it is a use-after-free. Bounded — this is the
        // matches on one screen, not in the scrollback.
        search.viewportSpans(
            terminal: terminal, columns: cols, rows: rows, into: &searchSpans)
        let beginResult = ghostty_render_state_begin_update(renderState, terminal)
        // Cleared here, under the same lock `write` takes and before it is
        // dropped, so that a write landing a moment from now sets it again and
        // earns the frame it is owed. Cleared *after* the unlock — as it was —
        // it erases exactly those writes: the bytes are in the terminal, no
        // frame is pending for them, and the pane holds a stale screen until
        // the next byte or the next click.
        if beginResult == GHOSTTY_SUCCESS { dirtyFlag.store(false) }
        // Highlights change no cell, so a match arriving, moving or being
        // stepped onto is invisible to libghostty's per-row dirty flags. This
        // is what makes it visible.
        let searchMoved = searchSpans != lastSearchSpans
        if searchMoved {
            // Element-wise rather than `lastSearchSpans = searchSpans`, which
            // would leave the two sharing one buffer and make the *next*
            // frame's `removeAll` copy it. Both stay uniquely referenced, so a
            // steady state costs one comparison and no allocation.
            lastSearchSpans.removeAll(keepingCapacity: true)
            lastSearchSpans.append(contentsOf: searchSpans)
        }
        let mustRebuild = forceFullRebuild || searchMoved
        forceFullRebuild = false
        lock.unlock()

        guard beginResult == GHOSTTY_SUCCESS else { return false }

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

        snapshot.dirty = (sizeChanged || mustRebuild) ? .full : Self.dirtyState(dirty)

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

        // Search matches, from the list taken under the lock above. Ours to
        // map rather than libghostty's: the C API stops at "a match is a
        // selection" and never exposes Ghostty's own per-row highlights.
        for span in searchSpans where span.row == y {
            snapshot.rowData[y].search.append(
                SearchHighlight(start: span.start, end: span.end, isSelected: span.isSelected))
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
