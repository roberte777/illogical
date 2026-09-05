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

    private var lastReportedSize: (cols: UInt16, rows: UInt16) = (0, 0)
    private var didSignalReady = false
    private var currentScale: CGFloat = 0

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
            return
        }
        setupRenderingIfNeeded()
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
        renderThread?.stop()
        renderThread = nil
        renderer = nil
        engine?.onWake = nil
    }

    private func attachEngine() {
        guard let engine else { return }
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
        // Draw synchronously so a live resize never shows a stale or
        // wrongly-sized surface.
        renderer.updateFrame()
        renderer.drawFrame(sync: true)
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

    override func becomeFirstResponder() -> Bool {
        renderer?.setFocus(true)
        renderThread?.wake()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        renderer?.setFocus(false)
        renderThread?.wake()
        return super.resignFirstResponder()
    }

    // MARK: - Input
    //
    // No local echo. The server is the single writer; what we type comes back
    // as `output` like everything else. See docs/CLIENT.md.

    override func keyDown(with event: NSEvent) {
        guard let bytes = Self.encode(event) else { return }
        delegate?.surface(self, send: bytes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// Minimal key encoding. libghostty-vt's `ghostty_encode_key` is the real
    /// answer and lands with full keyboard-protocol support in M3; this covers
    /// the common cases so the terminal is usable now.
    static func encode(_ event: NSEvent) -> [UInt8]? {
        let control = event.modifierFlags.contains(.control)
        let option = event.modifierFlags.contains(.option)

        switch Int(event.keyCode) {
        case kVK_Return: return [0x0d]
        case kVK_Tab: return [0x09]
        case kVK_Delete: return [0x7f]
        case kVK_ForwardDelete: return Array("\u{1b}[3~".utf8)
        case kVK_Escape: return [0x1b]
        case kVK_UpArrow: return Array("\u{1b}[A".utf8)
        case kVK_DownArrow: return Array("\u{1b}[B".utf8)
        case kVK_RightArrow: return Array("\u{1b}[C".utf8)
        case kVK_LeftArrow: return Array("\u{1b}[D".utf8)
        case kVK_Home: return Array("\u{1b}[H".utf8)
        case kVK_End: return Array("\u{1b}[F".utf8)
        case kVK_PageUp: return Array("\u{1b}[5~".utf8)
        case kVK_PageDown: return Array("\u{1b}[6~".utf8)
        default: break
        }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }

        if control, let scalar = characters.unicodeScalars.first {
            // Ctrl-A..Ctrl-Z and the handful of control punctuation.
            let value = scalar.value
            if value >= 0x61, value <= 0x7a { return [UInt8(value - 0x60)] }
            if value >= 0x41, value <= 0x5a { return [UInt8(value - 0x40)] }
            if value == 0x20 { return [0x00] }
        }

        guard let typed = event.characters, !typed.isEmpty else { return nil }
        var bytes = Array(typed.utf8)
        if option { bytes.insert(0x1b, at: 0) }
        return bytes
    }
}
