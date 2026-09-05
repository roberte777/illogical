//  TerminalSurfaceView.swift
//  The Metal surface a terminal draws into, and the input that drives it.
//
//  The view owns almost nothing. It holds a plain CALayer whose `contents`
//  the renderer swaps for a finished IOSurface, a render thread, and a
//  display link on that thread. Everything about *what* gets drawn lives in
//  `Renderer/`.
//
//  Two decisions worth explaining:
//
//  The layer is a CALayer, not a CAMetalLayer. `nextDrawable` blocks on the
//  display, which stalls a renderer that could otherwise be building the next
//  frame, and it behaves poorly under live resize. Handing a CALayer an
//  IOSurface avoids both. This is what Ghostty does.
//
//  The display link lives on the render thread, not the main thread. A
//  terminal at 120Hz would otherwise wake the main thread 120 times a second
//  just to ask "anything to draw?". And when there is nothing to draw for a
//  while we stop the link entirely: an idle terminal should cost nothing,
//  which is the whole thesis of this project.

import AppKit
import Carbon.HIToolbox
import GhosttyVt
import QuartzCore

/// Views are main-actor bound, and so is everything that answers them.
@MainActor
protocol TerminalSurfaceDelegate: AnyObject {
    /// The view has a window and a real size, so its grid dimensions are
    /// known. Attaching before this point would guess at cols/rows.
    func surfaceIsReady(_ surface: TerminalSurfaceView)
    func surface(_ surface: TerminalSurfaceView, send bytes: [UInt8])
    func surface(_ surface: TerminalSurfaceView, resizeTo cols: UInt16, rows: UInt16)
}

@MainActor
final class TerminalSurfaceView: NSView {
    weak var delegate: TerminalSurfaceDelegate?

    var engine: TerminalEngine? {
        didSet { attachEngine() }
    }

    /// Shown instead of the grid while the first snapshot is in flight.
    var statusText: String? {
        didSet { updateStatusLayer() }
    }

    private var renderer: TerminalRenderer?
    private var fontGrid: FontGrid?
    private var renderThread: RenderLoop?
    private var statusLayer: CATextLayer?

    /// Key, mouse and focus encoding. Nil until there is an engine, because
    /// every sequence it produces depends on that terminal's modes.
    private var inputEncoder: InputEncoder?

    private var lastReportedSize: (cols: UInt16, rows: UInt16) = (0, 0)
    private var didSignalReady = false
    private var currentScale: CGFloat = 0

    /// Matches `TerminalRenderer`'s own default, so the first real focus
    /// change is the first one either side acts on.
    private var isFocused = true
    private let focusObservers = ObserverTokens()

    /// How many buttons are down, which is a different question from which
    /// one this event is about: button-tracking mode reports motion only
    /// while something is held.
    private var buttonsDown = 0
    private var trackingArea: NSTrackingArea?

    private var scrollbar: ScrollbarOverlay?
    private var scrollbarHideWork: DispatchWorkItem?

    private let config = RendererConfig()
    private lazy var scrollAccumulator = ScrollAccumulator(
        precisionMultiplier: config.scrollMultiplierPrecision,
        discreteMultiplier: config.scrollMultiplierDiscrete)

    /// Point size of the terminal font. A config option eventually.
    private static let fontPointSize: Double = 13

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // Top-left gravity means a resize doesn't stretch the last frame
        // while we draw the next one.
        layer?.contentsGravity = .topLeft
        layer?.backgroundColor = Palette.background.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            teardownRendering()
            observeWindowFocus()
            return
        }
        setupRenderingIfNeeded()
        observeWindowFocus()
        window?.makeFirstResponder(self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window, window.backingScaleFactor != currentScale else { return }
        // A different display means different pixel metrics, so the font
        // grid and every rasterized glyph in it are wrong. Rebuild.
        teardownRendering()
        setupRenderingIfNeeded()
    }

    override func layout() {
        super.layout()
        guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
        setupRenderingIfNeeded()
        updateSurfaceSize()

        if !didSignalReady {
            didSignalReady = true
            lastReportedSize = gridSize
            delegate?.surfaceIsReady(self)
            return
        }
        reportSizeIfNeeded()
    }

    private func setupRenderingIfNeeded() {
        guard renderer == nil, let window, bounds.width > 1, bounds.height > 1 else { return }

        let scale = window.backingScaleFactor
        currentScale = scale

        let grid = FontGridSet.grid(
            family: nil, pointSize: Self.fontPointSize, scale: Double(scale))
        fontGrid = grid

        guard let layer else { return }
        layer.contentsScale = scale

        do {
            let context = try MetalContext.acquire()
            guard let engine else {
                // No engine yet: we still want the grid so `gridSize` can
                // answer, but there is nothing to render.
                return
            }
            let renderer = TerminalRenderer(
                context: context, grid: grid, layer: layer, source: engine)
            self.renderer = renderer
            updateSurfaceSize()

            let loop = RenderLoop(renderer: renderer)
            renderThread = loop
            loop.start(hostView: self)
            attachEngine()
        } catch {
            Trace.log("renderer init failed: \(error)")
        }
    }

    private func teardownRendering() {
        scrollbarHideWork?.cancel()
        scrollbarHideWork = nil
        scrollAccumulator.reset()
        renderThread?.stop()
        renderThread = nil
        renderer = nil
        engine?.onWake = nil
    }

    private func attachEngine() {
        guard let engine else {
            inputEncoder = nil
            return
        }

        if inputEncoder == nil {
            do {
                inputEncoder = try InputEncoder(engine: engine)
                updateEncoderSize()
            } catch {
                Trace.log("input encoder init failed: \(error)")
            }
        }

        // Restart a paused display link when output arrives. This is the
        // other half of stopping it when idle.
        let loop = renderThread
        engine.onWake = { [weak loop] in loop?.wake() }
        if renderer == nil {
            setupRenderingIfNeeded()
        } else {
            renderThread?.wake()
        }
        updateStatusLayer()
    }

    private func updateSurfaceSize() {
        guard let renderer, let window else { return }
        let scale = window.backingScaleFactor
        let pixelWidth = Int((bounds.width * scale).rounded())
        let pixelHeight = Int((bounds.height * scale).rounded())
        renderer.setScreenSize(
            width: pixelWidth, height: pixelHeight, scale: Double(scale))
        updateEncoderSize()
        // Draw synchronously so a live resize never shows a stale or
        // wrongly-sized surface.
        renderer.updateFrame()
        renderer.drawFrame(sync: true)
    }

    /// Hand the mouse encoder the geometry it turns a pixel into a cell with.
    ///
    /// It has to be the renderer's own numbers, padding included: a report
    /// that disagrees with what was drawn puts the click a cell away from
    /// where the user aimed.
    private func updateEncoderSize() {
        guard let inputEncoder, let renderer else { return }
        let size = renderer.currentSize
        var encoded = GhosttyMouseEncoderSize()
        encoded.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        encoded.screen_width = size.screen.width
        encoded.screen_height = size.screen.height
        encoded.cell_width = size.cell.width
        encoded.cell_height = size.cell.height
        encoded.padding_top = size.padding.top
        encoded.padding_bottom = size.padding.bottom
        encoded.padding_left = size.padding.left
        encoded.padding_right = size.padding.right
        inputEncoder.surfaceSize = encoded
        // The grid moved under the pointer, so the encoder's memory of the
        // cell it last reported is stale.
        inputEncoder.resetMouse()
    }

    /// The grid size this view can show, in cells.
    var gridSize: (cols: UInt16, rows: UInt16) {
        guard let renderer else {
            // Before the renderer exists, fall back to the shared grid's
            // metrics so an attach can still pick a sensible size.
            let scale = window?.backingScaleFactor ?? 2
            let grid = FontGridSet.grid(
                family: nil, pointSize: Self.fontPointSize, scale: Double(scale))
            let cellW = max(1, Double(grid.metrics.cellWidth))
            let cellH = max(1, Double(grid.metrics.cellHeight))
            let cols = max(1, Int(bounds.width * scale / cellW))
            let rows = max(1, Int(bounds.height * scale / cellH))
            return (UInt16(min(cols, Int(UInt16.max))), UInt16(min(rows, Int(UInt16.max))))
        }
        let g = renderer.gridSize
        return (g.columns, g.rows)
    }

    private func reportSizeIfNeeded() {
        let size = gridSize
        guard size != lastReportedSize else { return }
        lastReportedSize = size
        delegate?.surface(self, resizeTo: size.cols, rows: size.rows)
    }

    // MARK: - Status overlay

    /// The attaching/error message. A text layer rather than a drawn string:
    /// the view has no `draw(_:)` any more, its contents are an IOSurface.
    private func updateStatusLayer() {
        guard let text = statusText, engine == nil else {
            statusLayer?.removeFromSuperlayer()
            statusLayer = nil
            return
        }

        let textLayer =
            statusLayer
            ?? {
                let l = CATextLayer()
                l.alignmentMode = .center
                l.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                l.fontSize = 12
                l.foregroundColor = NSColor.secondaryLabelColor.cgColor
                l.contentsScale = window?.backingScaleFactor ?? 2
                layer?.addSublayer(l)
                statusLayer = l
                return l
            }()

        textLayer.string = text
        textLayer.frame = CGRect(
            x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
    }

    // MARK: - Focus
    //
    // Two things listen for focus, and they answer different questions. The
    // renderer wants it so the cursor is solid or hollow. The terminal wants
    // it only if the program inside asked for DEC mode 1004, which is how a
    // shell knows to redraw a prompt or an editor to stop blinking.
    //
    // Neither AppKit callback is enough on its own: `resignFirstResponder`
    // does not fire when the window stops being key, and the window
    // notifications do not fire when focus moves between two surfaces in one
    // window. Effective focus is the conjunction, so both feed one place.

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { updateFocus(isFirstResponder: true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { updateFocus(isFirstResponder: false) }
        return accepted
    }

    private func updateFocus(isFirstResponder: Bool) {
        let focused = isFirstResponder && (window?.isKeyWindow ?? false)
        guard focused != isFocused else { return }
        isFocused = focused

        renderer?.setFocus(focused)
        renderThread?.wake()

        if let bytes = inputEncoder?.encodeFocus(gained: focused) {
            delegate?.surface(self, send: bytes)
        }
    }

    private func observeWindowFocus() {
        focusObservers.clear()
        guard let window else { return }

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateFocus(isFirstResponder: self.window?.firstResponder === self)
                }
            }
            focusObservers.tokens.append(token)
        }
    }

    // MARK: - Scrolling
    //
    // The viewport is entirely client-side. We never synthesize wheel escape
    // sequences into the PTY, and we never tell the server where we are
    // looking: two people attached to one terminal scroll independently. The
    // tmux behaviour where one client's scroll moves everyone's window is a
    // bug we are deliberately not reproducing (docs/CLIENT.md, [ARCH t=323]).

    override func scrollWheel(with event: NSEvent) {
        guard let engine else { return }

        // Quantize first, and unconditionally. Every consumer of the wheel
        // works in rows, not pixels — a mouse report is one button press per
        // row — and the accumulator's remainder has to keep advancing even on
        // events we hand to the program, or a gesture that crosses into the
        // alternate screen carries a stale fraction across with it. This is
        // the order libghostty uses in `Surface.scrollCallback`.
        let rows = scrollAccumulator.wheelRows(
            scrollingDeltaY: Double(event.scrollingDeltaY),
            legacyDeltaY: Double(event.deltaY),
            precise: event.hasPreciseScrollingDeltas,
            cellHeight: Double(max(1, currentCellHeight)))
        let columns = scrollAccumulator.wheelColumns(
            scrollingDeltaX: Double(event.scrollingDeltaX),
            legacyDeltaX: Double(event.deltaX),
            precise: event.hasPreciseScrollingDeltas,
            cellWidth: Double(max(1, currentCellWidth)))

        // Then decide whose event it is. Two claimants write to the PTY
        // rather than moving the viewport: a program that asked for mouse
        // events gets wheel-button reports — scrolling inside `less` should
        // scroll `less` — and one sitting in the alternate screen with DECSET
        // 1007 gets cursor keys. `reportWheel` takes them in that order and
        // says whether either took it.
        //
        // It claims a tracking program's gesture even when it crossed no row
        // boundary, so the viewport does not creep on the leftover fraction.
        guard
            !reportWheel(
                rows: rows, columns: columns, mods: event.modifierFlags,
                at: convert(event.locationInWindow, from: nil))
        else { return }
        guard rows != 0 else { return }

        // Positive rows are up; the viewport axis counts down.
        engine.scroll(.delta(-rows))
        renderThread?.wake()
        showScrollbar()
    }

    /// Cell height in device pixels, which is the unit the viewport moves in.
    private var currentCellHeight: UInt32 {
        if let fontGrid { return fontGrid.metrics.cellHeight }
        return Self.fallbackMetrics(scale: window?.backingScaleFactor ?? 2).cellHeight
    }

    /// Cell width, for the horizontal axis of a wheel report. Nothing scrolls
    /// sideways here — the viewport has no horizontal axis — but buttons six
    /// and seven do, and they are counted in columns.
    private var currentCellWidth: UInt32 {
        if let fontGrid { return fontGrid.metrics.cellWidth }
        return Self.fallbackMetrics(scale: window?.backingScaleFactor ?? 2).cellWidth
    }

    private static func fallbackMetrics(scale: CGFloat) -> GridMetrics {
        FontGridSet.grid(family: nil, pointSize: fontPointSize, scale: Double(scale)).metrics
    }

    /// Jump back to the live output.
    func scrollToBottom() {
        guard let engine else { return }
        scrollAccumulator.reset()
        engine.scroll(.bottom)
        renderThread?.wake()
    }

    // MARK: - Scrollbar

    /// Show the position indicator and start its fade.
    ///
    /// An overlay indicator rather than a real `NSScrollView`: the terminal's
    /// content is an IOSurface the renderer owns, there is no document view
    /// to scroll, and the scrollable area changes shape as output arrives.
    private func showScrollbar() {
        guard let engine, let layer else { return }
        let state = engine.scrollbar
        guard state.canScroll else {
            scrollbar?.hide()
            return
        }

        let bar =
            scrollbar
            ?? {
                let b = ScrollbarOverlay()
                layer.addSublayer(b.layer)
                scrollbar = b
                return b
            }()

        bar.update(state, in: bounds, scale: window?.backingScaleFactor ?? 2)
        bar.show()

        // Fade out after a moment, like the system's own overlay scrollbars.
        scrollbarHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scrollbar?.hide() }
        scrollbarHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    // MARK: - Keyboard    //
    // No local echo. The server is the single writer; what we type comes back
    // as `output` like everything else. See docs/CLIENT.md.
    //
    // Nothing here decides what a key means. `KeyTranslation` says which
    // physical key it was and what text the layout produced; libghostty-vt
    // turns that into bytes against the terminal's own modes. That is the
    // whole point: the client and the server run the same encoder, so they
    // cannot disagree about what ctrl+shift+enter is.

    override func keyDown(with event: NSEvent) {
        guard let spec = KeyTranslation.spec(for: event) else { return }
        send(encodedKey: spec, isTyping: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let spec = KeyTranslation.spec(for: event) else { return }
        // Legacy encoding drops these. The Kitty protocol's event-reporting
        // flag is what makes them mean something, and whether it is set is
        // the encoder's business, not ours.
        send(encodedKey: spec)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let spec = KeyTranslation.modifierSpec(for: event) else { return }
        send(encodedKey: spec)
    }

    private func send(encodedKey spec: KeyEventSpec, isTyping: Bool = false) {
        guard let bytes = inputEncoder?.encode(key: spec), !bytes.isEmpty else { return }
        // Typing means you want to see what you are typing.
        //
        // Only on key-down. Under the Kitty protocol a bare modifier press
        // also produces bytes, and holding shift is not typing.
        if isTyping, config.scrollToBottomOnKeystroke { scrollToBottom() }
        delegate?.surface(self, send: bytes)
    }

    // MARK: - Mouse
    //
    // A mouse event is reported only when the program in the terminal asked
    // for it, and not even then if shift is held: shift is the escape hatch
    // that lets you select text inside a full-screen TUI, and every terminal
    // worth using honours it.

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonsDown += 1
        report(mouse: event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        buttonsDown = max(0, buttonsDown - 1)
        report(
            mouse: event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_LEFT)
    }

    override func mouseDragged(with event: NSEvent) {
        report(mouse: event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        buttonsDown += 1
        report(mouse: event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttonsDown = max(0, buttonsDown - 1)
        report(
            mouse: event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_RIGHT)
    }

    override func rightMouseDragged(with event: NSEvent) {
        report(
            mouse: event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let button = Self.button(forNumber: event.buttonNumber) else { return }
        buttonsDown += 1
        report(mouse: event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: button)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let button = Self.button(forNumber: event.buttonNumber) else { return }
        buttonsDown = max(0, buttonsDown - 1)
        report(mouse: event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: button)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let button = Self.button(forNumber: event.buttonNumber) else { return }
        report(mouse: event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: button)
    }

    override func mouseMoved(with event: NSEvent) {
        report(mouse: event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: nil)
    }

    override func mouseExited(with event: NSEvent) {
        // The pointer left the grid, so the encoder's memory of which cell it
        // was last in is wrong. The next motion inside should report.
        inputEncoder?.resetMouse()
    }

    /// Turn `NSEvent.buttonNumber` into a protocol button. 0 and 1 arrive
    /// through the dedicated left/right callbacks, so this starts at 2.
    private static func button(forNumber number: Int) -> GhosttyMouseButton? {
        switch number {
        case 2: return GHOSTTY_MOUSE_BUTTON_MIDDLE
        case 3: return GHOSTTY_MOUSE_BUTTON_EIGHT
        case 4: return GHOSTTY_MOUSE_BUTTON_NINE
        default: return nil
        }
    }

    private func report(
        mouse event: NSEvent, action: GhosttyMouseAction, button: GhosttyMouseButton?
    ) {
        guard isReportingMouse(event) else { return }
        report(
            action: action, button: button, mods: KeyTranslation.mods(event.modifierFlags),
            at: convert(event.locationInWindow, from: nil))
    }

    private func report(
        action: GhosttyMouseAction, button: GhosttyMouseButton?, mods: GhosttyMods,
        at point: NSPoint
    ) {
        guard let inputEncoder else { return }
        inputEncoder.anyButtonPressed = buttonsDown > 0
        // Surface pixels: the space the renderer lays the grid out in, origin
        // at the top-left, padding included.
        let backing = convertToBacking(point)
        let spec = MouseEventSpec(
            action: action,
            button: button,
            mods: mods,
            position: GhosttyMousePosition(x: Float(backing.x), y: Float(backing.y)))
        guard let bytes = inputEncoder.encode(mouse: spec), !bytes.isEmpty else { return }
        delegate?.surface(self, send: bytes)
    }

    /// Whether this event goes to the program rather than to the UI.
    ///
    /// Shift overrides reporting for buttons and motion, which is how you
    /// select text inside a full-screen TUI. That is Ghostty's default —
    /// `mouse-shift-capture` is `false` — but not the whole of its rule: it
    /// also lets the terminal itself take shift back with XTSHIFTESCAPE,
    /// which we do not implement, and exposes the choice as config, which we
    /// have nowhere to put yet.
    private func isReportingMouse(_ event: NSEvent) -> Bool {
        guard engine?.isMouseTracking == true else { return false }
        return !event.modifierFlags.contains(.shift)
    }

    // MARK: - The wheel's claimants

    /// Hand a quantized wheel gesture to the program in the terminal.
    ///
    /// Returns true when the program took it, which means the viewport must
    /// not move. Two claimants, in libghostty's order: one that asked for
    /// mouse events gets wheel-button reports, and one sitting in the
    /// alternate screen with DECSET 1007 gets cursor keys.
    ///
    /// Counts, not pixels. A wheel report is one button press per row, so a
    /// caller handing this raw trackpad deltas would emit ten reports where a
    /// mouse sends one.
    ///
    /// No shift override here, unlike the button path. Ghostty's
    /// `scrollCallback` has no shift gate at all — `mouseShiftCapture` is
    /// consulted for clicks and motion and nowhere else — so a shift-wheel
    /// inside a full-screen TUI goes to the program, and shift is only an
    /// escape hatch for selecting with the buttons.
    ///
    /// `mods` is the gesture's own modifier state, not
    /// `NSEvent.modifierFlags`: the latter is whatever is held right now,
    /// which is a different question and is untestable without faking global
    /// state.
    @discardableResult
    func reportWheel(
        rows: Int, columns: Int, mods: NSEvent.ModifierFlags, at point: NSPoint
    ) -> Bool {
        guard let inputEncoder, let engine else { return false }
        let encoded = KeyTranslation.mods(mods)

        if engine.isMouseTracking {
            for _ in 0..<abs(rows) {
                report(
                    action: GHOSTTY_MOUSE_ACTION_PRESS,
                    button: rows > 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE,
                    mods: encoded, at: point)
            }
            // Four/five and six/seven, mapped from the sign exactly as
            // Ghostty's `scrollCallback` maps it. Which physical direction
            // button six *is* the mouse header does not say and Ghostty's own
            // doc comment disagrees with the label used here, so this matches
            // by construction rather than by reasoning about it.
            for _ in 0..<abs(columns) {
                report(
                    action: GHOSTTY_MOUSE_ACTION_PRESS,
                    button: columns > 0 ? GHOSTTY_MOUSE_BUTTON_SIX : GHOSTTY_MOUSE_BUTTON_SEVEN,
                    mods: encoded, at: point)
            }
            // The wheel belongs to the program whether or not this particular
            // gesture crossed a row boundary.
            return true
        }

        guard let bytes = inputEncoder.encodeAlternateScroll(rows: rows) else { return false }
        delegate?.surface(self, send: bytes)
        return true
    }

    // MARK: - Tracking and the cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeInKeyWindow` rather than `.activeAlways`: a background
        // window reporting motion would wake a render thread we just paused.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        // An I-beam over text, as in every other terminal. It stays an I-beam
        // under mouse reporting: the program can draw its own affordances but
        // cannot change the pointer.
        addCursorRect(bounds, cursor: .iBeam)
    }
}

/// Notification tokens with a lifetime of their own.
///
/// `NSView.deinit` is nonisolated and may not touch the view's main-actor
/// state, so the tokens cannot be unregistered there directly. Holding them
/// here moves that cleanup off the view without leaving observers behind.
private final class ObserverTokens: @unchecked Sendable {
    var tokens: [any NSObjectProtocol] = []

    func clear() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }

    deinit { clear() }
}
