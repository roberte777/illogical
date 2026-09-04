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

/// Views are main-actor bound, and so is everything that answers them.
@MainActor
protocol TerminalSurfaceDelegate: AnyObject {
    /// The view has a window and a real size, so its grid dimensions are known.
    /// Attaching before this point would guess at cols/rows.
    func surfaceIsReady(_ surface: TerminalSurfaceView)
    func surface(_ surface: TerminalSurfaceView, send bytes: [UInt8])
    func surface(_ surface: TerminalSurfaceView, resizeTo cols: UInt16, rows: UInt16)
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
    private var lastReportedSize: (cols: UInt16, rows: UInt16) = (0, 0)
    private var didSignalReady = false

    override init(frame frameRect: NSRect) {
        let size: CGFloat = 13
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        boldFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        italicFont =
            NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let advance = font.maximumAdvancement.width
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        cellSize = CGSize(width: advance.rounded(.up), height: lineHeight)
        baselineOffset = -font.descender
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

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

        // Then text.
        //
        // The view is flipped so row 0 is at the top, but CoreText lays glyphs
        // out on an upward Y axis. Without this the text draws mirrored.
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        defer { context.restoreGState() }

        for (y, row) in grid.lines.enumerated() {
            let baseline = CGFloat(y) * cellSize.height + cellSize.height - baselineOffset
            for (x, cell) in row.cells.enumerated() {
                guard !cell.text.isEmpty, cell.text != " ", !cell.invisible else { continue }
                let color = resolvedForeground(cell, grid: grid)
                let face: NSFont =
                    cell.bold ? boldFont : (cell.italic ? italicFont : font)
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: face,
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
                    NSAttributedString(string: cell.text, attributes: attributes))
                context.textPosition = CGPoint(x: CGFloat(x) * cellSize.width, y: baseline)
                CTLineDraw(line, context)
            }
        }

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
