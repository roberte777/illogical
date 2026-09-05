//  TerminalSurfaceView.swift
//  Draws a terminal grid and turns key events into PTY bytes.
//
//  The renderer is CoreText over a monospaced font, drawing run-length spans of
//  identical style rather than per-cell. That is fast enough to be pleasant and,
//  more importantly, correct — it reads exactly what libghostty's render state
//  reports. Swapping in Metal means replacing `draw(_:)` and nothing else; the
//  grid it consumes is already a plain value type.
//
//  See docs/ROADMAP.md M3.

import AppKit
import Carbon.HIToolbox
import GhosttyVt

/// Views are main-actor bound, and so is everything that answers them.
@MainActor
protocol TerminalSurfaceDelegate: AnyObject {
    /// The view has a window and a real size, so its grid dimensions are known.
    /// Attaching before this point would guess at cols/rows.
    func surfaceIsReady(_ surface: TerminalSurfaceView)
    func surface(_ surface: TerminalSurfaceView, send bytes: [UInt8])
    func surface(_ surface: TerminalSurfaceView, resizeTo cols: UInt16, rows: UInt16)
    /// Forwarded only when the running program owns the wheel.
    func surface(_ surface: TerminalSurfaceView, scrollWheel event: NSEvent)
}

@MainActor
final class TerminalSurfaceView: NSView {
    weak var delegate: TerminalSurfaceDelegate?

    var engine: TerminalEngine? {
        didSet { needsDisplay = true }
    }

    /// Shown instead of the grid while the first snapshot is in flight.
    var statusText: String? {
        didSet { needsDisplay = true }
    }

    private let font: NSFont
    private let boldFont: NSFont
    private let italicFont: NSFont
    private let cellSize: CGSize
    private let baselineOffset: CGFloat
    private var redrawTimer: Timer?
    /// Wheel deltas arrive in points; a row is only scrolled once a whole
    /// cell's worth has accumulated, so trackpad scrolling is smooth rather
    /// than quantised to jumps.
    private var scrollAccumulator: CGFloat = 0
    private var selectionAnchor: (column: UInt16, row: UInt16)?
    /// Frame times, sampled only when tracing. The renderer choice should be
    /// made on numbers, not on the assumption that CoreText must be too slow.
    private var frameTimes: [Double] = []
    /// Frames per reported sample. Small enough that a slow renderer still
    /// reports within a few seconds.
    private static let frameSampleWindow =
        Int(ProcessInfo.processInfo.environment["ILLOGICAL_FRAME_WINDOW"] ?? "") ?? 120
    private var lastReportedSize: (cols: UInt16, rows: UInt16) = (0, 0)
    private var didSignalReady = false

    override init(frame frameRect: NSRect) {
        let size: CGFloat = 13
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        let advance = base.maximumAdvancement.width
        let lineHeight = (base.ascender - base.descender + base.leading).rounded(.up)
        let cell = CGSize(width: advance.rounded(.up), height: lineHeight)
        cellSize = cell
        baselineOffset = -base.descender

        // Pin the pen to the cell grid.
        //
        // cellSize.width is the advance rounded UP, so it is wider than the
        // glyph — 9.0 against 8.036 for the 13pt system mono. Drawing a run as
        // one CTLine lets CoreText advance by the font's own width, and the
        // error compounds: 1 cell of drift by 10 characters, 8.6 by 80, 20 by
        // 190. The per-cell renderer never showed it, because every glyph was
        // pinned to its own origin. kCTFontFixedAdvanceAttribute makes the
        // advance exactly one cell, so a run lands on the grid no matter which
        // face CoreText substitutes for a glyph the mono font lacks.
        font = Self.fixedAdvance(base, cell: cell.width)
        boldFont = Self.fixedAdvance(bold, cell: cell.width)
        italicFont = Self.fixedAdvance(italic, cell: cell.width)
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The same face, but advancing exactly one cell per glyph.
    private static func fixedAdvance(_ font: NSFont, cell: CGFloat) -> NSFont {
        let key = NSFontDescriptor.AttributeName(kCTFontFixedAdvanceAttribute as String)
        let descriptor = font.fontDescriptor.addingAttributes([key: cell])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            redrawTimer?.invalidate()
            redrawTimer = nil
            return
        }
        // A modest redraw tick. The engine reports whether anything actually
        // changed, so an idle terminal costs one cheap check per frame.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine, engine.needsDisplay else { return }
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
        if !didSignalReady {
            didSignalReady = true
            lastReportedSize = gridSize
            delegate?.surfaceIsReady(self)
            return
        }
        reportSizeIfNeeded()
    }

    /// The grid size this view can show, in cells.
    var gridSize: (cols: UInt16, rows: UInt16) {
        let cols = max(1, Int(bounds.width / cellSize.width))
        let rows = max(1, Int(bounds.height / cellSize.height))
        return (UInt16(min(cols, Int(UInt16.max))), UInt16(min(rows, Int(UInt16.max))))
    }

    private func reportSizeIfNeeded() {
        let size = gridSize
        guard size != lastReportedSize else { return }
        lastReportedSize = size
        delegate?.surface(self, resizeTo: size.cols, rows: size.rows)
    }

    /// Renders straight to a PNG, bypassing the window server.
    ///
    /// Screen capture needs a TCC grant the test machine may not have, and the
    /// renderer is exactly the kind of code where "it compiles" says nothing.
    /// ILLOGICAL_DUMP_PNG gets the real pixels out either way.
    func dumpPNG(to path: String) {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let frameStart = Trace.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if Trace.isEnabled {
                let micros = Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1000
                frameTimes.append(micros)
                if frameTimes.count == Self.frameSampleWindow {
                    let sorted = frameTimes.sorted()
                    func pct(_ p: Double) -> Int {
                        Int(sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))])
                    }
                    Trace.log(
                        "frame us: p50=\(pct(0.5)) p95=\(pct(0.95)) "
                            + "max=\(Int(sorted[sorted.count - 1])) "
                            + "n=\(sorted.count) grid=\(gridSize.cols)x\(gridSize.rows)")
                    frameTimes.removeAll(keepingCapacity: true)
                }
            }
        }

        guard let grid = engine?.grid() else {
            drawPlaceholder(in: context)
            return
        }

        context.setFillColor(grid.background.cgColor)
        context.fill(bounds)

        // Backgrounds first, as runs, so adjacent cells with the same colour
        // become one fill.
        for (y, row) in grid.lines.enumerated() {
            var runStart = 0
            var runColor: Grid.RGB?
            func flush(_ end: Int) {
                guard let color = runColor, end > runStart else { return }
                context.setFillColor(color.cgColor)
                context.fill(
                    CGRect(
                        x: CGFloat(runStart) * cellSize.width,
                        y: CGFloat(y) * cellSize.height,
                        width: CGFloat(end - runStart) * cellSize.width,
                        height: cellSize.height))
            }
            for (x, cell) in row.cells.enumerated() {
                let color = resolvedBackground(cell, grid: grid)
                if color != runColor {
                    flush(x)
                    runStart = x
                    runColor = color
                }
            }
            flush(row.cells.count)
        }

        // Then text, as runs.
        //
        // The first version built one CTLine per cell — ~11,000 a frame on a
        // full grid. Measured on a 192x58 grid of dense text, worst case, with
        // a full repaint every frame:
        //
        //     per cell    416ms p50   (2.4fps)
        //     per run     3.2ms p50   (19% of the 16.7ms budget)
        //
        // So the cost was never rasterization, which CoreGraphics caches well;
        // it was allocating and shaping 11,000 objects. Cells sharing a style
        // and holding a single ASCII scalar become one CTLine for the whole
        // run, exact because the font is monospaced and ligatures are off.
        // Anything else — wide characters, combining marks, emoji — still goes
        // cell by cell, where per-cell placement is the whole point.
        //
        // This is why there is no Metal renderer: at 5x headroom it would be a
        // glyph atlas and a shader pipeline bought for nothing measurable.
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (y, row) in grid.lines.enumerated() {
            let baseline = CGFloat(y) * cellSize.height + cellSize.height - baselineOffset
            var index = 0
            while index < row.cells.count {
                let cell = row.cells[index]
                guard hasInk(cell) else {
                    index += 1
                    continue
                }

                // Extend the run while style and simplicity hold. Spaces stay
                // inside it: ending a run at every word boundary would fragment
                // an ordinary line of prose into a dozen CTLines.
                var end = index + 1
                var lastInk = index
                var text = cell.text
                if isSimple(cell) {
                    while end < row.cells.count {
                        let next = row.cells[end]
                        guard !next.invisible, isSimple(next),
                            sameStyle(cell, next, grid: grid)
                        else { break }
                        text += next.text
                        if hasInk(next) { lastInk = end }
                        end += 1
                    }
                }

                // Trailing blanks carry no ink, so drop them rather than
                // shaping the rest of an empty line.
                if lastInk < end - 1 { text = String(text.prefix(lastInk - index + 1)) }
                draw(text, cell: cell, grid: grid, x: index, baseline: baseline, in: context)
                index = end
            }
        }
        context.restoreGState()

        drawScrollbar(grid, in: context)

        if let cursor = grid.cursor {
            context.setFillColor(
                grid.foreground.cgColor.copy(alpha: 0.75) ?? grid.foreground.cgColor)
            context.fill(
                CGRect(
                    x: CGFloat(cursor.x) * cellSize.width,
                    y: CGFloat(cursor.y) * cellSize.height,
                    width: cellSize.width,
                    height: cellSize.height))
        }

        engine?.markFrameDrawn()
    }

    /// Whether a cell can join a run: it advances exactly one cell and is a
    /// single scalar, so the fixed-advance font puts it on the grid.
    ///
    /// This asks libghostty for the width class rather than testing the scalar
    /// against an ASCII range. The range version sent box drawing, block
    /// elements and accented Latin down the per-cell path — 51.7ms a frame on
    /// a screen of U+2500, against 0.9ms for the same screen of ASCII. A TUI
    /// is mostly box drawing, so the whitelist excluded the case that needed
    /// batching most.
    private func isSimple(_ cell: Grid.Cell) -> Bool {
        cell.narrow && !cell.spacer && cell.text.unicodeScalars.count == 1
    }

    /// Whether a cell puts anything on screen. A blank cell still has ink when
    /// it is underlined or struck through — terminals draw those across spaces.
    private func hasInk(_ cell: Grid.Cell) -> Bool {
        if cell.invisible || cell.spacer { return false }
        if cell.underline || cell.strikethrough { return true }
        return !cell.text.isEmpty && cell.text != " "
    }

    /// Selection is deliberately absent: it only changes the background, which
    /// the fill pass has already drawn, so including it would split text runs
    /// at both selection edges for no visible difference.
    private func sameStyle(_ a: Grid.Cell, _ b: Grid.Cell, grid: Grid) -> Bool {
        resolvedForeground(a, grid: grid) == resolvedForeground(b, grid: grid)
            && a.bold == b.bold && a.italic == b.italic && a.faint == b.faint
            && a.underline == b.underline && a.strikethrough == b.strikethrough
            && a.inverse == b.inverse
    }

    private func draw(
        _ text: String, cell: Grid.Cell, grid: Grid, x: Int, baseline: CGFloat,
        in context: CGContext
    ) {
        let color = resolvedForeground(cell, grid: grid)
        let face: NSFont = cell.bold ? boldFont : (cell.italic ? italicFont : font)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: face,
            // Off, so a run's glyphs sit on exact cell boundaries.
            .ligature: 0,
            .foregroundColor: NSColor(
                srgbRed: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: cell.faint ? 0.65 : 1.0),
        ]
        if cell.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if cell.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: CGFloat(x) * cellSize.width, y: baseline)
        CTLineDraw(line, context)
    }

    /// A thin overlay scrollbar on the trailing edge, shown only while there
    /// is history to move through.
    private func drawScrollbar(_ grid: Grid, in context: CGContext) {
        let bar = grid.scrollbar
        guard bar.isScrollable, bar.total > 0 else { return }

        let width: CGFloat = 4
        let inset: CGFloat = 2
        let trackHeight = bounds.height
        let thumbHeight = max(
            24, trackHeight * CGFloat(bar.visible) / CGFloat(bar.total))
        let travel = trackHeight - thumbHeight
        let progress =
            bar.total > bar.visible
            ? CGFloat(bar.offset) / CGFloat(bar.total - bar.visible) : 0

        context.setFillColor(
            CGColor(gray: 1, alpha: bar.isAtBottom ? 0.14 : 0.28))
        let rect = CGRect(
            x: bounds.width - width - inset,
            y: travel * min(max(progress, 0), 1),
            width: width,
            height: thumbHeight)
        context.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
        context.fillPath()
    }

    private func resolvedBackground(_ cell: Grid.Cell, grid: Grid) -> Grid.RGB {
        if cell.selected { return Grid.RGB(r: 60, g: 80, b: 110) }
        if cell.inverse { return cell.foreground ?? grid.foreground }
        return cell.background ?? grid.background
    }

    private func resolvedForeground(_ cell: Grid.Cell, grid: Grid) -> Grid.RGB {
        if cell.inverse { return cell.background ?? grid.background }
        return cell.foreground ?? grid.foreground
    }

    private func drawPlaceholder(in context: CGContext) {
        context.setFillColor(NSColor.textBackgroundColor.cgColor)
        context.fill(bounds)
        guard let text = statusText else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)
    }

    // MARK: - Scrolling
    //
    // Native scrollback: this moves libghostty's viewport, and never
    // synthesises wheel escape sequences into the PTY. The running program
    // does not see a fake wheel, and history stays the terminal's own.

    override func scrollWheel(with event: NSEvent) {
        guard let engine else { return }

        // An alternate-screen program (vim, htop) owns the wheel: there is no
        // scrollback to move through, so forward it as mouse input instead.
        if engine.isAlternateScreen {
            delegate?.surface(self, scrollWheel: event)
            return
        }

        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= cellSize.height }
        scrollAccumulator += delta

        let rows = Int((scrollAccumulator / cellSize.height).rounded(.towardZero))
        guard rows != 0 else { return }
        scrollAccumulator -= CGFloat(rows) * cellSize.height
        // Positive deltaY is a scroll up, which is negative in row terms.
        engine.scroll(rows: -rows)
        needsDisplay = true
    }

    // MARK: - Input
    //
    // No local echo. The server is the single writer; what we type comes back
    // as `output` like everything else. And no hand-rolled escape sequences:
    // libghostty encodes against the terminal's current modes, so the Kitty
    // keyboard protocol, modifyOtherKeys and mouse reporting all follow the
    // running program instead of a table we maintain.

    override func keyDown(with event: NSEvent) {
        guard let bytes = engine?.encode(key: event) else { return }
        // Any keystroke means "follow the output again".
        engine?.scrollToBottom()
        delegate?.surface(self, send: bytes)
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier-only events matter to the Kitty protocol; libghostty
        // decides whether they encode to anything.
        guard let bytes = engine?.encode(key: event, action: GHOSTTY_KEY_ACTION_PRESS),
            !bytes.isEmpty
        else { return }
        delegate?.surface(self, send: bytes)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = cell(for: event)

        if forwardMouse(
            event, button: GHOSTTY_MOUSE_BUTTON_LEFT, action: GHOSTTY_MOUSE_ACTION_PRESS)
        {
            return
        }

        switch event.clickCount {
        case 2: engine?.selectWord(atColumn: point.column, row: point.row)
        case 3: engine?.selectLine(atColumn: point.column, row: point.row)
        default:
            selectionAnchor = point
            engine?.clearSelection()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = cell(for: event)
        if forwardMouse(
            event, button: GHOSTTY_MOUSE_BUTTON_LEFT, action: GHOSTTY_MOUSE_ACTION_MOTION)
        {
            return
        }
        guard let anchor = selectionAnchor else { return }
        engine?.select(from: anchor, to: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if forwardMouse(
            event, button: GHOSTTY_MOUSE_BUTTON_LEFT, action: GHOSTTY_MOUSE_ACTION_RELEASE)
        {
            return
        }
        selectionAnchor = nil
    }

    /// Send the event to the running program if it asked for mouse reporting.
    /// Returns true when it was forwarded, so selection does not also happen.
    private func forwardMouse(
        _ event: NSEvent, button: GhosttyMouseButton, action: GhosttyMouseAction
    ) -> Bool {
        guard let engine, engine.wantsMouseReporting else { return false }
        // Shift is the conventional override for "let me select anyway".
        if event.modifierFlags.contains(.shift) { return false }
        let point = cell(for: event)
        guard
            let bytes = engine.encode(
                mouseButton: button, action: action, mods: event.modifierFlags,
                column: point.column, row: point.row)
        else { return true }
        delegate?.surface(self, send: bytes)
        return true
    }

    /// The cell under an event, clamped to the grid.
    private func cell(for event: NSEvent) -> (column: UInt16, row: UInt16) {
        let local = convert(event.locationInWindow, from: nil)
        let size = gridSize
        let column = Int(local.x / cellSize.width)
        let row = Int(local.y / cellSize.height)
        return (
            UInt16(min(max(column, 0), Int(size.cols) - 1)),
            UInt16(min(max(row, 0), Int(size.rows) - 1))
        )
    }

    // MARK: - Copy

    @objc func copy(_ sender: Any?) {
        guard let text = engine?.selectedText(), !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        guard let bytes = engine?.encodePaste(text) else { return }
        engine?.scrollToBottom()
        delegate?.surface(self, send: bytes)
    }

    @objc override func selectAll(_ sender: Any?) {
        engine?.selectAll()
        needsDisplay = true
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): engine?.hasSelection ?? false
        case #selector(paste(_:)), #selector(selectAll(_:)): true
        default: true
        }
    }
}

extension Grid.RGB {
    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
