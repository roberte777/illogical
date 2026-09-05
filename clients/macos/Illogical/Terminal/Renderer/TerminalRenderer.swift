//  TerminalRenderer.swift
//  Terminal state in, three draw calls out.
//
//  Ported from libghostty's `src/renderer/generic.zig`. The shape of a frame:
//
//    updateFrame()   pull the dirty rows out of the terminal, shape them,
//                    rasterize any new glyphs, and write GPU-ready structs
//                    into `cells`. CPU only.
//    drawFrame()     upload `cells`, encode three passes, present.
//
//  Both run on the renderer thread. The terminal lock is held only inside
//  `updateFrame`, and only for the `beginUpdate` call, so the connection's
//  reader thread keeps feeding the terminal while a frame is assembled.
//
//  The three passes, in order:
//
//    1. bg_color   — one triangle for the default background.
//    2. cell_bg    — one triangle; the fragment shader indexes a per-cell
//                    colour buffer. No geometry per cell.
//    3. cell_text  — one instanced quad per glyph, underline, strikethrough,
//                    overline and cursor.

import Foundation
import Metal
import QuartzCore
import simd

final class TerminalRenderer: @unchecked Sendable {
    private let context: MetalContext
    private let grid: FontGrid
    private let shaper: TextShaper
    private weak var source: TerminalRenderSource?

    var config: RendererConfig

    /// Guards everything the render thread and the main thread both touch.
    private let mutex = NSLock()

    // Swap chain. Three deep: the CPU builds N+1 while the GPU draws N and
    // the display scans out N-1.
    private static let swapChainCount = 3
    private var frames: [FrameState]
    private var frameIndex = 0
    private let frameSemaphore = DispatchSemaphore(value: swapChainCount)

    private var cells = CellContents()
    private var uniforms = IllogicalUniforms()
    private var size: RendererSize
    /// The view of the terminal this frame is built from.
    ///
    /// Not private only so the tests can assert on what came out of
    /// libghostty's render state; a wrong `wide` flag is much easier to
    /// diagnose as a field than as a pixel.
    let snapshot = TerminalSnapshot()

    /// Set when `updateFrame` produced something new to draw. `drawFrame`
    /// clears it, and skips the whole frame if it was already clear.
    private var cellsRebuilt = false

    private(set) var focused = true
    /// Reset whenever the terminal produces output, so the cursor is solid
    /// while you type rather than winking mid-keystroke.
    private var blinkEpoch = CACurrentMediaTime()
    /// The blink phase the last frame was drawn with. Nil before the first.
    private var lastBlinkPhase: Bool?

    /// The layer we hand finished IOSurfaces to.
    private let layer: CALayer

    init(
        context: MetalContext,
        grid: FontGrid,
        layer: CALayer,
        source: TerminalRenderSource,
        config: RendererConfig = RendererConfig()
    ) {
        self.context = context
        self.grid = grid
        self.layer = layer
        self.source = source
        self.config = config
        self.shaper = TextShaper(grid: grid)

        frames = (0..<Self.swapChainCount).map { _ in FrameState(device: context.device) }

        size = RendererSize(
            screen: ScreenSize(width: 0, height: 0),
            cell: CellSize(width: grid.metrics.cellWidth, height: grid.metrics.cellHeight),
            padding: EdgePadding())

        uniforms.cell_size = SIMD2<Float>(
            Float(grid.metrics.cellWidth), Float(grid.metrics.cellHeight))
        uniforms.min_contrast = config.minimumContrast
        uniforms.use_display_p3 = false
        uniforms.use_linear_blending = config.blending.isLinear
        uniforms.use_linear_correction = config.blending == .linearCorrected
    }

    deinit {
        // Wait for every in-flight frame before the GPU resources go away.
        for _ in 0..<Self.swapChainCount { frameSemaphore.wait() }
        for _ in 0..<Self.swapChainCount { frameSemaphore.signal() }
    }

    var cellSize: CellSize {
        CellSize(width: grid.metrics.cellWidth, height: grid.metrics.cellHeight)
    }

    // MARK: - Configuration from the view

    /// Tell the renderer the surface changed size. Sizes are in device
    /// pixels.
    func setScreenSize(width: Int, height: Int, scale: Double) {
        mutex.lock()
        defer { mutex.unlock() }

        size.screen = ScreenSize(
            width: UInt32(max(0, min(width, context.maxTextureSize))),
            height: UInt32(max(0, min(height, context.maxTextureSize))))
        size.cell = cellSize

        let padX = UInt32((config.windowPaddingX * scale).rounded())
        let padY = UInt32((config.windowPaddingY * scale).rounded())
        size.balancePadding(
            explicit: EdgePadding(top: padY, bottom: padY, right: padX, left: padX),
            mode: .balanced)

        updateScreenSizeUniformsLocked()
    }

    /// Grid dimensions for the current surface size.
    var gridSize: GridDimensions {
        mutex.lock()
        defer { mutex.unlock() }
        return size.grid
    }

    /// Screen, cell and padding for the current surface, in device pixels.
    ///
    /// Input needs it: a mouse report is a cell coordinate, and turning a
    /// pointer position into one has to use the same padding the frame was
    /// laid out with.
    var currentSize: RendererSize {
        mutex.lock()
        defer { mutex.unlock() }
        return size
    }

    func setFocus(_ focused: Bool) {
        mutex.lock()
        defer { mutex.unlock() }
        self.focused = focused
        // A focus change swaps the cursor between solid and hollow, so the
        // frame must be redrawn even though no cell changed.
        cellsRebuilt = true
    }

    /// Called when the terminal produces output, to keep the cursor solid
    /// during activity.
    func resetBlink() {
        mutex.lock()
        defer { mutex.unlock() }
        blinkEpoch = CACurrentMediaTime()
    }

    /// Caller must hold the mutex.
    private func updateScreenSizeUniformsLocked() {
        let terminalSize = size.terminal

        // Space around the grid that no cell covers, including the explicit
        // padding. The background shader uses this to decide what the
        // padding is filled with.
        let blank = size.screen.blankPadding(
            size.padding,
            grid: GridDimensions(
                columns: UInt16(cells.columns), rows: UInt16(cells.rows)),
            cell: CellSize(width: grid.metrics.cellWidth, height: grid.metrics.cellHeight)
        ).adding(size.padding)

        uniforms.projection_matrix = Self.ortho2d(
            left: -Float(size.padding.left),
            right: Float(terminalSize.width + size.padding.right),
            bottom: Float(terminalSize.height + size.padding.bottom),
            top: -Float(size.padding.top))
        uniforms.grid_padding = SIMD4<Float>(
            Float(blank.top), Float(blank.right), Float(blank.bottom), Float(blank.left))
        uniforms.screen_size = SIMD2<Float>(
            Float(size.screen.width), Float(size.screen.height))
    }

    /// Orthographic projection onto the [-1, 1] clip cube, y down.
    private static func ortho2d(
        left: Float, right: Float, bottom: Float, top: Float
    )
        -> simd_float4x4
    {
        let sx = 2 / (right - left)
        let sy = 2 / (top - bottom)
        let tx = -(right + left) / (right - left)
        let ty = -(top + bottom) / (top - bottom)
        return simd_float4x4(
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(tx, ty, 0, 1))
    }

    // MARK: - Frame update

    /// Whether anything has changed that would make a new frame differ from
    /// the last one. Cheap enough to call from the display link every tick.
    var needsFrame: Bool {
        if let source, source.isDirty { return true }
        mutex.lock()
        defer { mutex.unlock() }
        if cellsRebuilt { return true }
        // A blinking cursor needs frames even when nothing else changes —
        // but only when the phase actually flips. Redrawing on every tick
        // would keep a display link alive at 120 Hz to animate something
        // that changes twice a second.
        return blinkingCursorLocked && blinkVisible != lastBlinkPhase
    }

    private var blinkingCursorLocked: Bool {
        snapshot.cursor.hasViewport && snapshot.cursor.visible && snapshot.cursor.blinking
            && focused
    }

    private var blinkVisible: Bool {
        let elapsed = CACurrentMediaTime() - blinkEpoch
        return Int(elapsed / config.cursorBlinkInterval) % 2 == 0
    }

    /// Pull terminal state and rebuild the CPU-side cell buffers.
    func updateFrame() {
        guard let source else { return }

        mutex.lock()
        defer { mutex.unlock() }

        // The only part of this that touches the terminal is inside
        // `updateSnapshot`, which takes and releases the terminal lock
        // itself.
        guard source.updateSnapshot(into: snapshot) else { return }

        rebuildCellsLocked()
    }

    /// Caller must hold the mutex.
    private func rebuildCellsLocked() {
        let cols = snapshot.columns
        let rows = snapshot.rows
        guard cols > 0, rows > 0 else { return }

        let gridSizeChanged = cells.columns != cols || cells.rows != rows
        if gridSizeChanged {
            cells.resize(columns: cols, rows: rows)
            uniforms.grid_size = SIMD2<UInt16>(UInt16(cols), UInt16(rows))
            updateScreenSizeUniformsLocked()
        }

        let fullRebuild = snapshot.dirty == .full || gridSizeChanged
        if fullRebuild {
            cells.reset()

            switch config.paddingColor {
            case .background:
                uniforms.padding_extend = 0
            case .extend, .extendAlways:
                // Assume all four directions; the `.extend` heuristic may
                // switch the vertical ones off per row below.
                uniforms.padding_extend = UInt8(
                    ILLO_PADDING_EXTEND_LEFT.rawValue | ILLO_PADDING_EXTEND_RIGHT.rawValue
                        | ILLO_PADDING_EXTEND_UP.rawValue | ILLO_PADDING_EXTEND_DOWN.rawValue)
            }
        }

        uniforms.bg_color = SIMD4<UInt8>(
            snapshot.background.r, snapshot.background.g, snapshot.background.b,
            UInt8(max(0, min(255, (config.backgroundOpacity * 255).rounded()))))

        for y in 0..<rows {
            if !fullRebuild {
                guard y < snapshot.rowDirty.count, snapshot.rowDirty[y] else { continue }
                cells.clear(row: y)
            }
            rebuildRowLocked(y)
        }

        rebuildCursorLocked()
        lastBlinkPhase = blinkVisible

        cellsRebuilt = true
    }

    /// Caller must hold the mutex.
    private func rebuildRowLocked(_ y: Int) {
        guard y < snapshot.rowData.count else { return }
        let row = snapshot.rowData[y]
        let cols = min(row.cells.count, cells.columns)
        guard cols > 0 else { return }

        let defaultFg = snapshot.foreground
        let defaultBg = snapshot.background

        // Vertical padding extension is only applied when the edge row looks
        // like it will not smear. See `neverExtendBackground`.
        if config.paddingColor == .extend {
            if y == 0 {
                setPaddingExtend(
                    ILLO_PADDING_EXTEND_UP, on: !neverExtendBackground(row, cols: cols))
            } else if y == cells.rows - 1 {
                setPaddingExtend(
                    ILLO_PADDING_EXTEND_DOWN, on: !neverExtendBackground(row, cols: cols))
            }
        }

        // Shape the whole row up front. Runs are cached on their content, so
        // an unchanged line costs a hash lookup per run.
        let cursorX: UInt16? =
            (snapshot.cursor.hasViewport && Int(snapshot.cursor.y) == y)
            ? snapshot.cursor.x : nil
        let runs = shaper.runs(
            row: row.cells, graphemes: row.graphemes, cols: cols,
            selection: row.selection, cursorX: cursorX)

        // Walk runs and cells together. Both are in increasing x order, so
        // this is a merge, not a search.
        var runIndex = 0
        var shaped: [ShapedCell] = []
        var shapedIndex = 0
        var shapedRunOffset = 0

        func loadRun(_ i: Int) {
            shaped = shaper.shape(runs[i])
            shapedIndex = 0
            shapedRunOffset = Int(runs[i].offset)
        }
        if !runs.isEmpty { loadRun(0) }

        for x in 0..<cols {
            let cell = row.cells[x]

            let selected: Bool = {
                guard let sel = row.selection else { return false }
                // A spacer tail belongs to the character before it.
                let compare = cell.wide == .spacerTail ? UInt16(max(0, x - 1)) : UInt16(x)
                return compare >= sel.start && compare <= sel.end
            }()

            // Colours as the SGR style asks for them, before selection and
            // inversion are applied.
            let bgStyle = cell.bg
            let fgStyle = cell.fg.present ? cell.fg : defaultFg

            let bg: PackedRGB = {
                if selected {
                    if let c = config.selectionBackground {
                        return PackedRGB(r: c.r, g: c.g, b: c.b)
                    }
                    // With no configured colour, the selection background is
                    // the foreground colour, which reads correctly against
                    // any theme.
                    return defaultFg
                }
                // Two things make us paint the foreground colour as the
                // background: the inverse flag, and a "covering" glyph such
                // as FULL BLOCK, where using fg as bg is what makes padding
                // extension look right. If both are true they cancel.
                let inverse = cell.flags.contains(.inverse)
                if inverse != CellRules.isCovering(cell.codepoint) { return fgStyle }
                return bgStyle
            }()

            let fg: PackedRGB = {
                let finalBg = bgStyle.present ? bgStyle : defaultBg
                if selected {
                    if let c = config.selectionForeground {
                        return PackedRGB(r: c.r, g: c.g, b: c.b)
                    }
                    return defaultBg
                }
                return cell.flags.contains(.inverse) ? finalBg : fgStyle
            }()

            let alpha: UInt8 = cell.flags.contains(.faint) ? config.faintAlpha : 255

            // Background.
            do {
                let rgb = bg.present ? bg : defaultBg
                let bgAlpha: UInt8 = {
                    // Selected and inverted cells are always opaque: they are
                    // an explicit visual signal and shouldn't fade.
                    if selected { return 255 }
                    if cell.flags.contains(.inverse) { return 255 }
                    if config.backgroundOpacityCells && bgStyle.present {
                        return UInt8(
                            max(0, min(255, (255 * config.backgroundOpacity).rounded())))
                    }
                    // An explicit background is opaque.
                    if bgStyle.present { return 255 }
                    // Otherwise draw nothing and let the surface background
                    // show through, which is what makes transparency work.
                    return 0
                }()
                cells.setBackground(
                    row: y, column: x,
                    IllogicalCellBg(rgb.r, rgb.g, rgb.b, bgAlpha))
            }

            // Invisible suppresses every foreground element, decorations
            // included. This matches xterm; some terminals keep the
            // decorations, but hiding a password shouldn't leave underlines
            // spelling out its length.
            if cell.flags.contains(.invisible) { continue }

            // Underlines are drawn before text so that a coloured underline
            // passes behind descenders instead of cutting through them.
            if cell.underline != .none {
                let color = cell.underlineColor.present ? cell.underlineColor : fg
                addSprite(
                    cell.underline.sprite, x: x, y: y, color: color, alpha: alpha)
            }

            if cell.flags.contains(.overline) {
                addSprite(.overline, x: x, y: y, color: fg, alpha: alpha)
            }

            // Advance to the run covering this column.
            while runIndex < runs.count
                && shapedIndex >= shaped.count
            {
                runIndex += 1
                if runIndex < runs.count { loadRun(runIndex) }
            }

            if runIndex < runs.count {
                // Shaping is supposed to produce monotonically increasing x,
                // and we sort the rare runs where CoreText says it didn't.
                // A cell left behind the cursor would otherwise never match
                // and would stall every glyph after it in the run.
                while shapedIndex < shaped.count
                    && shapedRunOffset + Int(shaped[shapedIndex].x) < x
                {
                    shapedIndex += 1
                }
                while shapedIndex < shaped.count
                    && shapedRunOffset + Int(shaped[shapedIndex].x) == x
                {
                    addGlyph(
                        shaped[shapedIndex], run: runs[runIndex], row: row,
                        x: x, y: y, cols: cols, color: fg, alpha: alpha)
                    shapedIndex += 1
                }
            }

            if cell.flags.contains(.strikethrough) {
                addSprite(.strikethrough, x: x, y: y, color: fg, alpha: alpha)
            }
        }
    }

    private func setPaddingExtend(_ flag: IllogicalPaddingExtend, on: Bool) {
        if on {
            uniforms.padding_extend |= UInt8(flag.rawValue)
        } else {
            uniforms.padding_extend &= ~UInt8(flag.rawValue)
        }
    }

    /// Whether extending this row's background into the padding would look
    /// wrong.
    ///
    /// The case this guards against is a row that is mostly default
    /// background with a coloured run at one end: extending would smear that
    /// colour across the window edge. libghostty's heuristic is that a row is
    /// safe to extend from only if it is entirely non-default.
    private func neverExtendBackground(_ row: RenderRow, cols: Int) -> Bool {
        for x in 0..<cols {
            let cell = row.cells[x]
            if cell.bg.present { continue }
            if cell.flags.contains(.inverse) && cell.fg.present { continue }
            // A cell with the default background means this row would smear.
            return true
        }
        return false
    }

    private func addSprite(
        _ sprite: Sprite?, x: Int, y: Int, color: PackedRGB, alpha: UInt8
    ) {
        guard let sprite else { return }
        guard
            let render = try? grid.renderGlyph(
                .sprite, glyph: sprite.rawValue,
                options: GlyphRenderOptions(cellWidth: 1))
        else { return }
        guard !render.glyph.isEmpty else { return }

        cells.add(
            row: y,
            IllogicalCellText(
                glyph_pos: SIMD2<UInt32>(render.glyph.atlasX, render.glyph.atlasY),
                glyph_size: SIMD2<UInt32>(render.glyph.width, render.glyph.height),
                bearings: SIMD2<Int16>(
                    Int16(clamping: render.glyph.offsetX),
                    Int16(clamping: render.glyph.offsetY)),
                grid_pos: SIMD2<UInt16>(UInt16(x), UInt16(y)),
                color: SIMD4<UInt8>(color.r, color.g, color.b, alpha),
                atlas: UInt8(ILLO_ATLAS_GRAYSCALE.rawValue),
                bools: 0))
    }

    private func addGlyph(
        _ shapedCell: ShapedCell,
        run: TextRun,
        row: RenderRow,
        x: Int,
        y: Int,
        cols: Int,
        color: PackedRGB,
        alpha: UInt8
    ) {
        let cell = row.cells[x]
        let cp = cell.codepoint

        // Constrain symbol-like glyphs so they fit their cell(s). Nerd Font
        // codepoints have their own per-icon rules; anything else that is
        // symbol-like just gets scaled down to fit.
        let constraintKind: GlyphConstraintKind =
            NerdFontConstraints.constraint(for: cp) != nil
            ? .nerdFont(cp)
            : (CellRules.isSymbol(cp) ? .fit : .none)

        let constraintWidth = CellRules.constraintWidth(
            x: x, cols: cols,
            gridWidth: cell.gridWidth,
            codepoint: cp,
            previousCodepoint: x > 0 ? row.cells[x - 1].codepoint : nil,
            nextCodepoint: x + 1 < cols ? row.cells[x + 1].codepoint : nil)

        let options = GlyphRenderOptions(
            cellWidth: cell.gridWidth,
            constraintKind: constraintKind,
            constraintWidth: constraintWidth,
            thicken: config.fontThicken,
            thickenStrength: config.fontThickenStrength)

        guard
            let render = try? grid.renderGlyph(
                run.fontIndex, glyph: shapedCell.glyphIndex, options: options)
        else { return }

        // A zero-sized glyph draws nothing, so don't spend an instance on it.
        guard !render.glyph.isEmpty else { return }

        cells.add(
            row: y,
            IllogicalCellText(
                glyph_pos: SIMD2<UInt32>(render.glyph.atlasX, render.glyph.atlasY),
                glyph_size: SIMD2<UInt32>(render.glyph.width, render.glyph.height),
                bearings: SIMD2<Int16>(
                    Int16(clamping: Int(render.glyph.offsetX) + Int(shapedCell.xOffset)),
                    Int16(clamping: Int(render.glyph.offsetY) + Int(shapedCell.yOffset))),
                grid_pos: SIMD2<UInt16>(UInt16(x), UInt16(y)),
                color: SIMD4<UInt8>(color.r, color.g, color.b, alpha),
                atlas: UInt8(
                    render.presentation == .emoji
                        ? ILLO_ATLAS_COLOR.rawValue : ILLO_ATLAS_GRAYSCALE.rawValue),
                bools: CellRules.noMinContrast(cp)
                    ? UInt8(ILLO_CELL_NO_MIN_CONTRAST.rawValue) : 0))
    }

    /// Caller must hold the mutex.
    private func rebuildCursorLocked() {
        cells.setCursor(nil, style: nil)
        // A cursor position of "impossible" disables the shader's
        // recolouring of text under the cursor.
        uniforms.cursor_pos = SIMD2<UInt16>(UInt16.max, UInt16.max)

        guard snapshot.cursor.hasViewport else { return }
        guard let style = cursorStyle() else { return }

        let cursorCell = snapshot.cursorCell

        // The cursor draws over the character, so if we're on the tail of a
        // wide character move back to its head and cover both cells.
        let wide: Bool
        let x: UInt16
        if snapshot.cursor.wideTail {
            wide = true
            x = snapshot.cursor.x > 0 ? snapshot.cursor.x - 1 : 0
        } else {
            wide = cursorCell?.wide == .wide
            x = snapshot.cursor.x
        }

        let color: PackedRGB = {
            // OSC 12 wins if the program set it.
            if snapshot.cursorColor.present { return snapshot.cursorColor }
            return snapshot.foreground
        }()

        let alpha: UInt8 =
            focused
            ? UInt8(max(0, min(255, (255 * config.cursorOpacity).rounded(.up))))
            : 255

        let render: GlyphRender?
        switch style {
        case .block, .blockHollow, .bar, .underline:
            let sprite: Sprite = {
                switch style {
                case .block: return .cursorRect
                case .blockHollow: return .cursorHollowRect
                case .bar: return .cursorBar
                case .underline: return .cursorUnderline
                case .lock: return .cursorRect
                }
            }()
            render = try? grid.renderGlyph(
                .sprite, glyph: sprite.rawValue,
                options: GlyphRenderOptions(cellWidth: wide ? 2 : 1))
        case .lock:
            render = grid.renderCodepoint(
                0xF023,  // lock symbol
                style: .regular, presentation: .text,
                options: GlyphRenderOptions(cellWidth: wide ? 2 : 1))
        }

        guard let render, !render.glyph.isEmpty else { return }

        cells.setCursor(
            IllogicalCellText(
                glyph_pos: SIMD2<UInt32>(render.glyph.atlasX, render.glyph.atlasY),
                glyph_size: SIMD2<UInt32>(render.glyph.width, render.glyph.height),
                bearings: SIMD2<Int16>(
                    Int16(clamping: render.glyph.offsetX),
                    Int16(clamping: render.glyph.offsetY)),
                grid_pos: SIMD2<UInt16>(x, snapshot.cursor.y),
                color: SIMD4<UInt8>(color.r, color.g, color.b, alpha),
                atlas: UInt8(ILLO_ATLAS_GRAYSCALE.rawValue),
                bools: UInt8(ILLO_CELL_IS_CURSOR_GLYPH.rawValue)),
            style: style)

        // Only a solid block hides the character under it, so only a block
        // needs the shader to recolour that character.
        if style == .block {
            uniforms.cursor_pos = SIMD2<UInt16>(x, snapshot.cursor.y)
            uniforms.cursor_wide = wide
            // Text under the cursor is drawn in the background colour, so it
            // reads as a knockout.
            let textColor = snapshot.background
            uniforms.cursor_color = SIMD4<UInt8>(textColor.r, textColor.g, textColor.b, 255)
        }
    }

    /// Which cursor to draw, if any.
    ///
    /// The order is a priority system, and it matters: a password prompt
    /// shows a lock even if the program hid the cursor, and an unfocused
    /// surface always shows a hollow box so you can still see where you are.
    private func cursorStyle() -> CursorStyle? {
        let c = snapshot.cursor
        guard c.hasViewport else { return nil }
        if c.passwordInput { return .lock }
        if !c.visible { return nil }
        if !focused { return .blockHollow }
        if c.blinking && !blinkVisible { return nil }
        switch c.style {
        case .bar: return .bar
        case .block: return .block
        case .blockHollow: return .blockHollow
        case .underline: return .underline
        }
    }

    // MARK: - Drawing

    /// Encode and present a frame.
    ///
    /// `sync` waits for the GPU and sets the layer contents on the calling
    /// thread, which is what a live resize needs so the window never shows a
    /// stale or wrongly-sized surface.
    func drawFrame(sync: Bool = false) {
        mutex.lock()

        guard size.screen.width > 0, size.screen.height > 0 else {
            mutex.unlock()
            return
        }

        // Nothing changed since the last frame: the surface already on the
        // layer is correct, so there is nothing to do at all.
        guard cellsRebuilt || sync else {
            mutex.unlock()
            return
        }
        cellsRebuilt = false

        let width = Int(size.screen.width)
        let height = Int(size.screen.height)
        let pixelFormat = context.blending.pixelFormat

        // Copy out everything the encode needs, then drop the lock: the CPU
        // is free to start building the next frame while we talk to Metal.
        let uniformsCopy = uniforms
        let bgCells = cells.bgCells
        let fgRows = cells.fgRows
        mutex.unlock()

        frameSemaphore.wait()
        frameIndex = (frameIndex + 1) % Self.swapChainCount
        let frame = frames[frameIndex]

        if frame.target?.width != width || frame.target?.height != height {
            frame.resize(width: width, height: height, pixelFormat: pixelFormat)
        }
        guard let target = frame.target else {
            frameSemaphore.signal()
            return
        }

        frame.uniforms.sync(uniformsCopy)
        frame.cellsBg.sync(bgCells)
        let fgCount = frame.cells.sync(concatenating: fgRows)

        // Upload the atlases only if a glyph was added since this frame slot
        // last saw them. The read lock is what keeps the atlas from being
        // grown out from under the copy.
        grid.lock.readLock()
        if grid.atlasGrayscale.modified > frame.grayscaleModified {
            frame.grayscaleModified = grid.atlasGrayscale.modified
            frame.syncAtlas(grid.atlasGrayscale, texture: &frame.grayscale, format: .r8Unorm)
        }
        if grid.atlasColor.modified > frame.colorModified {
            frame.colorModified = grid.atlasColor.modified
            frame.syncAtlas(
                grid.atlasColor, texture: &frame.color, format: .bgra8Unorm_srgb)
        }
        grid.lock.unlock()

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            frameSemaphore.signal()
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            frameSemaphore.signal()
            return
        }

        let uniformIndex = Int(ILLO_BUFFER_UNIFORMS.rawValue)
        let bgIndex = Int(ILLO_BUFFER_CELL_BG.rawValue)

        // 1. The surface background. We don't use the clear colour for this
        //    because that would mean doing the colour space conversion on the
        //    CPU; the shader already knows how.
        encoder.setRenderPipelineState(context.bgColorPipeline)
        encoder.setFragmentBuffer(frame.uniforms.buffer, offset: 0, index: uniformIndex)
        encoder.setFragmentBuffer(frame.cellsBg.buffer, offset: 0, index: bgIndex)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 2. Per-cell backgrounds, still just one triangle.
        encoder.setRenderPipelineState(context.cellBgPipeline)
        encoder.setFragmentBuffer(frame.uniforms.buffer, offset: 0, index: uniformIndex)
        encoder.setFragmentBuffer(frame.cellsBg.buffer, offset: 0, index: bgIndex)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 3. Text, one instanced quad per glyph.
        if fgCount > 0 {
            encoder.setRenderPipelineState(context.cellTextPipeline)
            encoder.setVertexBuffer(
                frame.cells.buffer, offset: 0, index: Int(ILLO_BUFFER_VERTEX.rawValue))
            encoder.setVertexBuffer(frame.uniforms.buffer, offset: 0, index: uniformIndex)
            encoder.setVertexBuffer(frame.cellsBg.buffer, offset: 0, index: bgIndex)
            encoder.setFragmentBuffer(frame.uniforms.buffer, offset: 0, index: uniformIndex)
            encoder.setFragmentTexture(frame.grayscale, index: Int(ILLO_TEXTURE_GRAYSCALE.rawValue))
            encoder.setFragmentTexture(frame.color, index: Int(ILLO_TEXTURE_COLOR.rawValue))
            encoder.drawPrimitives(
                type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                instanceCount: fgCount)
        }

        encoder.endEncoding()

        let semaphore = frameSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.commit()

        if sync {
            commandBuffer.waitUntilCompleted()
            setLayerContents(target.surface, sync: true)
        } else {
            setLayerContents(target.surface, sync: false)
        }
    }

    /// Hand a finished surface to the layer.
    ///
    /// Layer contents must be set on the main thread or the window flickers,
    /// so an async frame hops there. We re-check the size on arrival: during
    /// a resize an async frame can land just after a sync one and would
    /// otherwise put a stale, wrongly-sized surface on screen.
    private func setLayerContents(_ surface: IOSurfaceRef, sync: Bool) {
        if sync || Thread.isMainThread {
            layer.contents = surface
            return
        }
        // An IOSurface is designed to be handed between threads and
        // processes, and a CALayer we only touch on the main thread; neither
        // is Sendable, so the hop needs an explicit box.
        let box = UncheckedBox((layer: layer, surface: surface))
        DispatchQueue.main.async {
            let layer = box.value.layer
            let surface = box.value.surface
            let bounds = layer.bounds
            let scale = layer.contentsScale
            let width = Int(bounds.size.width * scale)
            let height = Int(bounds.size.height * scale)
            guard
                width == IOSurfaceGetWidth(surface),
                height == IOSurfaceGetHeight(surface)
            else { return }
            layer.contents = surface
        }
    }
}

/// What the renderer needs from whatever owns the terminal.
protocol TerminalRenderSource: AnyObject {
    /// Cheap check for pending work, called from the display link.
    var isDirty: Bool { get }

    /// Take a consistent view of the terminal into `snapshot`.
    ///
    /// The implementation is responsible for holding the terminal lock for
    /// as little as possible, and for consuming the render state's dirty
    /// flags once it has read them.
    func updateSnapshot(into snapshot: TerminalSnapshot) -> Bool
}

/// Carries a non-Sendable value across a concurrency boundary where the
/// author has checked that it is safe.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
