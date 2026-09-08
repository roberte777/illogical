//  SurfaceInputTests.swift
//  From an AppKit event to the bytes that go on the wire.
//
//  `InputTests` covers the encoder. This covers the wiring around it: that
//  the responder methods reach it at all, that nothing is echoed locally, and
//  that the terminal's modes still decide the answer once a real NSEvent is
//  the thing driving it.

import AppKit
import Carbon.HIToolbox
import GhosttyVt
import XCTest

@MainActor
final class SurfaceInputTests: XCTestCase {
    /// Records what the surface asked to send, which in the app is a protocol
    /// `input` frame.
    private final class Recorder: TerminalSurfaceDelegate {
        var sent: [[UInt8]] = []
        var resizes: [SurfaceSize] = []
        var readied = false
        var focusedCount = 0
        /// What `performClose` should report: true means a pane was closed,
        /// false that this is the only one and the window should take it.
        var closesPane = false
        var closeRequests = 0
        var firstFrames: [Date] = []

        var bytes: [UInt8] { sent.flatMap { $0 } }
        var text: String { String(decoding: bytes, as: UTF8.self) }

        func surfaceIsReady(_ surface: TerminalSurfaceView) { readied = true }
        func surface(_ surface: TerminalSurfaceView, send bytes: [UInt8]) { sent.append(bytes) }
        func surface(_ surface: TerminalSurfaceView, resizeTo size: SurfaceSize) {
            resizes.append(size)
        }
        func surfaceDidBecomeFocused(_ surface: TerminalSurfaceView) { focusedCount += 1 }
        func surface(_ surface: TerminalSurfaceView, didPresentFirstFrameAt moment: Date) {
            firstFrames.append(moment)
        }
        func surfaceShouldClose(_ surface: TerminalSurfaceView) -> Bool {
            closeRequests += 1
            return closesPane
        }
    }

    private func surface() throws -> (TerminalSurfaceView, TerminalEngine, Recorder) {
        let engine = try TerminalEngine(cols: 80, rows: 24)
        let view = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let recorder = Recorder()
        view.delegate = recorder
        view.engine = engine
        return (view, engine, recorder)
    }

    private func write(_ engine: TerminalEngine, _ text: String) {
        var bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { engine.write(UnsafeRawBufferPointer($0)) }
    }

    private func keyDown(
        _ keyCode: Int, characters: String, mods: NSEvent.ModifierFlags = [],
        type: NSEvent.EventType = .keyDown
    )
        -> NSEvent?
    {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: mods,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode))
    }

    func testTypingReachesTheWire() throws {
        let (view, _, recorder) = try surface()
        view.keyDown(with: try XCTUnwrap(keyDown(kVK_ANSI_A, characters: "a")))
        view.keyDown(with: try XCTUnwrap(keyDown(kVK_Return, characters: "\r")))
        XCTAssertEqual(recorder.text, "a\r")
    }

    /// No local echo: the server is the single writer and what we type comes
    /// back as `output`. A surface that painted its own keystrokes would
    /// break desync recovery, which is the thing that makes the whole
    /// architecture cheap.
    func testNothingIsEchoedLocally() throws {
        let (view, engine, _) = try surface()
        view.keyDown(with: try XCTUnwrap(keyDown(kVK_ANSI_A, characters: "a")))

        let snapshot = TerminalSnapshot()
        XCTAssertTrue(engine.updateSnapshot(into: snapshot))
        XCTAssertFalse(snapshot.rowData[0].cells[0].hasText)
    }

    /// The same event, two answers, decided by a mode the *program* set. This
    /// is the whole reason input goes through libghostty rather than a table.
    func testTerminalModeDecidesTheEncoding() throws {
        let (view, engine, recorder) = try surface()
        let up = try XCTUnwrap(keyDown(kVK_UpArrow, characters: "\u{f700}"))

        view.keyDown(with: up)
        XCTAssertEqual(recorder.text, "\u{1b}[A")

        recorder.sent.removeAll()
        write(engine, "\u{1b}[?1h")
        view.keyDown(with: up)
        XCTAssertEqual(recorder.text, "\u{1b}OA")
    }

    /// A bare modifier says nothing in legacy mode, and says something under
    /// the Kitty protocol — but only with `report_all` (flag 8), not merely
    /// with event reporting. Both are the encoder's call, not ours, which is
    /// the point: nothing here had to know that rule.
    func testModifiersAreSilentUntilTheProtocolAsks() throws {
        let (view, engine, recorder) = try surface()
        let shift = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(
                    rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x02),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: UInt16(kVK_Shift)))

        view.flagsChanged(with: shift)
        XCTAssertTrue(recorder.sent.isEmpty)

        // disambiguate | report_events | report_all
        write(engine, "\u{1b}[>11u")
        view.flagsChanged(with: shift)
        XCTAssertEqual(recorder.text, "\u{1b}[57441;2u")
    }

    /// Mouse events go nowhere until a program turns reporting on, so a click
    /// in an ordinary shell never writes junk to the PTY.
    func testMouseIsSilentWithoutTracking() throws {
        let (view, _, recorder) = try surface()
        let click = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 20, y: 20),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1))
        view.mouseDown(with: click)
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    /// Focus is reported only under DEC mode 1004, and only on a real edge.
    /// Without the gate a shell would print `[I` every time the window came
    /// forward; without the edge check, every responder shuffle would repeat
    /// the last report.
    ///
    /// Effective focus is first responder *and* key window, and an xctest
    /// process cannot take key focus, so the edge under test here is the
    /// losing one. `InputTests` covers both directions of the encoding.
    func testFocusReportsOncePerEdge() throws {
        let (view, engine, recorder) = try surface()
        write(engine, "\u{1b}[?1004h")

        _ = view.resignFirstResponder()
        XCTAssertEqual(recorder.text, "\u{1b}[O")

        recorder.sent.removeAll()
        _ = view.resignFirstResponder()
        _ = view.becomeFirstResponder()
        XCTAssertTrue(recorder.sent.isEmpty, "same state is not an edge")
    }

    func testFocusIsSilentWithoutMode1004() throws {
        let (view, _, recorder) = try surface()
        _ = view.resignFirstResponder()
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    // MARK: - The wheel

    /// `reportWheel` is the seam native scrollback calls once it has whole
    /// rows. It answers whether the program took the gesture, which is how
    /// the viewport knows to stay put.
    func testWheelGoesNowhereWithoutAClaimant() throws {
        let (view, _, recorder) = try surface()
        XCTAssertFalse(view.reportWheel(rows: 3, columns: 0, mods: [], at: .zero))
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    /// One wheel-button press per row, not one per event. A trackpad delivers
    /// a few pixels at a time, so a seam taking raw deltas would report ten
    /// times where a mouse reports once.
    func testWheelReportsOnePressPerRow() throws {
        let (view, engine, recorder) = try surface()
        // The report needs geometry, and without a window there is no
        // renderer to supply it, so mouse reports cannot be checked for their
        // cell here — only that the program claimed the gesture.
        write(engine, "\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertTrue(view.reportWheel(rows: 3, columns: 0, mods: [], at: .zero))
        XCTAssertEqual(recorder.sent.count, 3)
        for report in recorder.sent {
            // Button 64 is wheel-up in SGR.
            XCTAssertTrue(String(decoding: report, as: UTF8.self).hasPrefix("\u{1b}[<64;"))
        }
    }

    /// Horizontal is buttons six and seven, one press per column. Untested
    /// until now because every caller passed `columns: 0`; native scrollback's
    /// `wheelColumns` is about to start feeding it.
    func testWheelReportsColumnsAsButtonsSixAndSeven() throws {
        let (view, engine, recorder) = try surface()
        write(engine, "\u{1b}[?1000h\u{1b}[?1006h")

        XCTAssertTrue(view.reportWheel(rows: 0, columns: 2, mods: [], at: .zero))
        XCTAssertEqual(recorder.sent.count, 2)
        for report in recorder.sent {
            XCTAssertTrue(String(decoding: report, as: UTF8.self).hasPrefix("\u{1b}[<66;"))
        }

        recorder.sent.removeAll()
        XCTAssertTrue(view.reportWheel(rows: 0, columns: -1, mods: [], at: .zero))
        XCTAssertEqual(recorder.sent.count, 1)
        XCTAssertTrue(recorder.text.hasPrefix("\u{1b}[<67;"))
    }

    /// A diagonal gesture reports both axes, vertical first — the order
    /// `scrollCallback` uses.
    func testDiagonalWheelReportsBothAxes() throws {
        let (view, engine, recorder) = try surface()
        write(engine, "\u{1b}[?1000h\u{1b}[?1006h")

        XCTAssertTrue(view.reportWheel(rows: 1, columns: 1, mods: [], at: .zero))
        XCTAssertEqual(recorder.sent.count, 2)
        XCTAssertTrue(String(decoding: recorder.sent[0], as: UTF8.self).hasPrefix("\u{1b}[<64;"))
        XCTAssertTrue(String(decoding: recorder.sent[1], as: UTF8.self).hasPrefix("\u{1b}[<66;"))
    }

    /// A gesture that crossed no boundary still belongs to the program, so
    /// the viewport must not move on the leftover fraction. This is what
    /// native scrollback's `guard !claimed` depends on.
    func testTrackingProgramClaimsEvenAZeroGesture() throws {
        let (view, engine, recorder) = try surface()
        write(engine, "\u{1b}[?1000h\u{1b}[?1006h")

        XCTAssertTrue(view.reportWheel(rows: 0, columns: 0, mods: [], at: .zero))
        XCTAssertTrue(recorder.sent.isEmpty, "claimed, but nothing to report")
    }

    /// In the alternate screen with DECSET 1007 and no mouse reporting, the
    /// wheel becomes cursor keys — which is what makes the wheel work in
    /// `less`.
    func testWheelBecomesCursorKeysUnderAlternateScroll() throws {
        let (view, engine, recorder) = try surface()
        write(engine, "\u{1b}[?1049h\u{1b}[?1007h")

        XCTAssertTrue(view.reportWheel(rows: -2, columns: 0, mods: [], at: .zero))
        XCTAssertEqual(recorder.text, "\u{1b}[B\u{1b}[B")
    }

    // MARK: - Selection

    /// The surface needs a window before it has a renderer, and it needs a
    /// renderer before it knows the geometry a selection is measured in. Not
    /// a *key* window — an xctest process cannot have one — just a window.
    private func windowedSurface() throws -> (TerminalSurfaceView, TerminalEngine, NSWindow) {
        let engine = try TerminalEngine(cols: 80, rows: 20)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        // Otherwise `close()` releases it and ARC releases it again.
        window.isReleasedWhenClosed = false
        let view = TerminalSurfaceView(frame: window.contentLayoutRect)
        window.contentView = view
        view.engine = engine
        view.layoutSubtreeIfNeeded()
        return (view, engine, window)
    }

    /// The same, with somewhere for what the surface sends to land.
    private func recordingSurface() throws -> (
        TerminalSurfaceView, TerminalEngine, NSWindow, Recorder
    ) {
        let (view, engine, window) = try windowedSurface()
        let recorder = Recorder()
        view.delegate = recorder
        return (view, engine, window, recorder)
    }

    /// Take the view out of its window first, which stops the render thread.
    private func tearDown(_ view: TerminalSurfaceView, _ window: NSWindow) {
        window.contentView = NSView(frame: view.frame)
        window.close()
    }

    /// A pointer event inside a given cell.
    ///
    /// `across` is where in the cell horizontally, because libghostty
    /// includes a cell in a drag only once the pointer is past its midpoint.
    /// The grid does not start at the view's origin — the renderer pads it —
    /// so this goes through the renderer's own geometry rather than assuming.
    ///
    /// The arithmetic here is deliberately AppKit-free: divide the renderer's
    /// pixels by the scale, then flip against the view's height, because a
    /// window point is bottom-up. Building it with `convertFromBacking`
    /// instead would produce whatever point the view's own conversion is the
    /// inverse of — which passes every test below even when that conversion is
    /// wrong, and did.
    private func click(
        _ view: TerminalSurfaceView, column: Int, row: Int, across: Double = 0.5,
        type: NSEvent.EventType
    ) throws -> NSEvent {
        let size = try XCTUnwrap(view.rendererSizeForTesting)
        let scale = view.window?.backingScaleFactor ?? 1
        let backing = NSPoint(
            x: Double(size.padding.left) + (Double(column) + across) * Double(size.cell.width),
            y: Double(size.padding.top) + (Double(row) + 0.5) * Double(size.cell.height))
        let local = NSPoint(x: backing.x / scale, y: backing.y / scale)
        return try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                // Window coordinates are bottom-up; the surface is flipped.
                location: NSPoint(x: local.x, y: view.bounds.height - local.y),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1))
    }

    /// Press, drag, release through the responder methods, ending in text on
    /// the way to the clipboard.
    func testDragSelectsThroughTheResponderChain() throws {
        let (view, engine, window) = try windowedSurface()
        defer { tearDown(view, window) }
        write(engine, "hello world")

        view.mouseDown(with: try click(view, column: 0, row: 0, type: .leftMouseDown))
        view.mouseDragged(
            with: try click(view, column: 4, row: 0, across: 0.8, type: .leftMouseDragged))
        view.mouseUp(with: try click(view, column: 4, row: 0, across: 0.8, type: .leftMouseUp))

        XCTAssertEqual(engine.selectionText(), "hello")
        XCTAssertTrue(engine.hasSelection)
    }

    /// The same drag, several rows down. Row 0 is the one row where an error
    /// in the pointer-to-row mapping is invisible, so the test above cannot
    /// see one; this is that test at a row the arithmetic has to reach.
    func testDragSelectsOnARowBelowTheFirst() throws {
        let (view, engine, window) = try windowedSurface()
        defer { tearDown(view, window) }
        for i in 0..<10 { write(engine, "line\(i) here\r\n") }

        view.mouseDown(with: try click(view, column: 0, row: 7, type: .leftMouseDown))
        view.mouseDragged(
            with: try click(view, column: 4, row: 7, across: 0.8, type: .leftMouseDragged))
        view.mouseUp(with: try click(view, column: 4, row: 7, across: 0.8, type: .leftMouseUp))

        XCTAssertEqual(engine.selectionText(), "line7")
    }

    /// And the row the renderer is told to highlight is the row that was
    /// dragged over. The text being right is only half of it: the selection
    /// reaches the frame as a per-row range, and a frame that highlights row 0
    /// for a selection on row 7 looks exactly like a broken hit test.
    func testHighlightLandsOnTheDraggedRow() throws {
        let (view, engine, window) = try windowedSurface()
        defer { tearDown(view, window) }
        for i in 0..<10 { write(engine, "line\(i) here\r\n") }

        view.mouseDown(with: try click(view, column: 0, row: 7, type: .leftMouseDown))
        view.mouseDragged(
            with: try click(view, column: 4, row: 7, across: 0.8, type: .leftMouseDragged))

        let snapshot = TerminalSnapshot()
        XCTAssertTrue(engine.updateSnapshot(into: snapshot))
        XCTAssertNotNil(snapshot.rowData[7].selection, "row 7 is not highlighted")
        XCTAssertNil(snapshot.rowData[0].selection, "row 0 is highlighted and should not be")
    }

    /// A real session has history behind it. The viewport is then a window
    /// into a page list rather than the whole of one, which is the state the
    /// tests above never reach.
    func testDragSelectsWithHistoryBehindTheViewport() throws {
        let (view, engine, window) = try windowedSurface()
        defer { tearDown(view, window) }
        for i in 0..<60 { write(engine, "line\(i) here\r\n") }

        view.mouseDown(with: try click(view, column: 0, row: 5, type: .leftMouseDown))
        view.mouseDragged(
            with: try click(view, column: 4, row: 5, across: 0.8, type: .leftMouseDragged))

        let snapshot = TerminalSnapshot()
        XCTAssertTrue(engine.updateSnapshot(into: snapshot))
        XCTAssertNotNil(snapshot.rowData[5].selection, "row 5 is not highlighted")
        XCTAssertNil(snapshot.rowData[0].selection, "row 0 is highlighted and should not be")
        XCTAssertEqual(engine.selectionText()?.hasSuffix(" "), false)
    }

    /// The highlight follows the drag rather than accumulating behind it: a
    /// row that was selected a moment ago and is not now must stop being
    /// drawn as selected, even though nothing in it changed.
    func testHighlightLeavesNoTrailBehindTheDrag() throws {
        let (view, engine, window) = try windowedSurface()
        defer { tearDown(view, window) }
        for i in 0..<60 { write(engine, "line\(i) here\r\n") }

        let snapshot = TerminalSnapshot()
        view.mouseDown(with: try click(view, column: 0, row: 8, type: .leftMouseDown))
        view.mouseDragged(
            with: try click(view, column: 4, row: 8, across: 0.8, type: .leftMouseDragged))
        XCTAssertTrue(engine.updateSnapshot(into: snapshot))
        XCTAssertNotNil(snapshot.rowData[8].selection)

        // Drag back up to the anchor's own row, so row 8 is no longer in it.
        view.mouseDragged(
            with: try click(view, column: 4, row: 6, across: 0.8, type: .leftMouseDragged))
        XCTAssertTrue(engine.updateSnapshot(into: snapshot))
        XCTAssertNotNil(snapshot.rowData[6].selection, "row 6 is not highlighted")
        XCTAssertNotNil(snapshot.rowData[7].selection, "row 7 is not highlighted")
    }

    /// A press at a point measured from the *bottom* of the window — which is
    /// the only kind AppKit delivers — selects the row the renderer drew at
    /// that height.
    ///
    /// Stated without a single view conversion in it, because the conversions
    /// are what this is testing. `convertToBacking` negates y on a flipped
    /// view: the surface is measured from the top and the backing store is
    /// measured from the bottom, so a press two thirds of the way down a pane
    /// arrived as a negative surface y, clamped to the first row, and every
    /// selection landed on the first visible line.
    func testAPressSelectsTheRowUnderIt() throws {
        let (view, engine, window) = try windowedSurface()
        defer { tearDown(view, window) }
        for i in 0..<15 { write(engine, "line\(i) here\r\n") }

        let size = try XCTUnwrap(view.rendererSizeForTesting)
        let scale = window.backingScaleFactor
        // The middle of row 6, down from the top of the surface, in points.
        let topDown = (Double(size.padding.top) + 6.5 * Double(size.cell.height)) / scale
        let left = Double(size.padding.left) / scale

        func event(_ type: NSEvent.EventType, x: Double) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type,
                    location: NSPoint(x: x, y: view.bounds.height - topDown),
                    modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
        }

        let cell = Double(size.cell.width) / scale
        view.mouseDown(with: try event(.leftMouseDown, x: left + 0.5 * cell))
        view.mouseDragged(with: try event(.leftMouseDragged, x: left + 4.8 * cell))

        XCTAssertEqual(engine.selectionText(), "line6")
    }

    /// And the same point, reported to the program rather than selected with.
    ///
    /// The other half of the same conversion, and the half with no coverage at
    /// all: `InputTests` hands the encoder pixel positions directly, and every
    /// wheel test here reports at the origin, where a negated y is still zero.
    /// So a click in a full-screen program went unreported entirely — a
    /// position off the surface encodes to no bytes at all — for exactly as
    /// long as selection was landing on the first line, and nothing said so.
    func testAReportedClickCarriesTheCellUnderIt() throws {
        let (view, engine, window, recorder) = try recordingSurface()
        defer { tearDown(view, window) }
        write(engine, "\u{1b}[?1000h\u{1b}[?1006h")

        view.mouseDown(with: try click(view, column: 3, row: 6, type: .leftMouseDown))

        // SGR reports are 1-based: column 4, row 7.
        XCTAssertEqual(recorder.text, "\u{1b}[<0;4;7M")
    }

    /// Typing drops the selection, as it does in every terminal.
    func testTypingClearsTheSelection() throws {
        let (view, engine, window) = try windowedSurface()
        defer { tearDown(view, window) }
        write(engine, "hello world")
        engine.selectAll()
        XCTAssertTrue(engine.hasSelection)

        view.keyDown(with: try XCTUnwrap(keyDown(kVK_ANSI_A, characters: "a")))
        XCTAssertFalse(engine.hasSelection)
    }

    /// Copy is disabled with nothing selected, which is the only thing the
    /// Edit menu can tell the user before they try it.
    func testCopyIsValidatedAgainstTheSelection() throws {
        let (view, engine, window) = try windowedSurface()
        defer { tearDown(view, window) }
        write(engine, "hello")

        let copyItem = NSMenuItem(
            title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        XCTAssertFalse(view.validateMenuItem(copyItem))

        engine.selectAll()
        XCTAssertTrue(view.validateMenuItem(copyItem))
    }

    /// A program with mouse tracking on gets the click; the selection gesture
    /// does not start behind its back.
    func testMouseTrackingTakesPrecedenceOverSelection() throws {
        let (view, engine, window) = try windowedSurface()
        defer { tearDown(view, window) }
        write(engine, "hello world\u{1b}[?1000h\u{1b}[?1006h")

        view.mouseDown(with: try click(view, column: 0, row: 0, type: .leftMouseDown))
        view.mouseDragged(
            with: try click(view, column: 5, row: 0, across: 0.8, type: .leftMouseDragged))
        XCTAssertFalse(engine.hasSelection)
    }

    // MARK: - Closing

    /// ⌘W. The menu item walks the responder chain, so the focused surface
    /// gets first refusal and closes its pane; when it is the only pane it
    /// declines and the standard Close Window item does its usual job. That
    /// is how a terminal takes ⌘W without fighting SwiftUI for the shortcut.
    func testCloseGoesToThePaneFirst() throws {
        let (view, _, recorder) = try surface()
        recorder.closesPane = true

        view.performClose(nil)
        XCTAssertEqual(recorder.closeRequests, 1)
    }

    /// A refusal is still a request. #41 moved the *policy* into
    /// `SessionStore.closeSurfacePane` and left this mechanism alone: the
    /// delegate is asked exactly once either way, and only its answer decides
    /// whether the window sees the event.
    func testTheDelegateIsAskedOnceEvenWhenItDeclines() throws {
        let (view, _, recorder) = try surface()
        recorder.closesPane = false

        view.performClose(nil)
        XCTAssertEqual(recorder.closeRequests, 1)
    }

    /// A surface in a *closable* window, so `performClose:` can be observed.
    /// `windowedSurface`'s bare `.titled` window has no close button, and
    /// `performClose:` on one of those beeps instead of closing — which would
    /// make the assertion below pass against a fall-through that was deleted.
    private func closableSurface() throws -> (TerminalSurfaceView, Recorder, NSWindow) {
        let engine = try TerminalEngine(cols: 80, rows: 20)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalSurfaceView(frame: window.contentLayoutRect)
        let recorder = Recorder()
        view.delegate = recorder
        window.contentView = view
        view.engine = engine
        view.layoutSubtreeIfNeeded()
        return (view, recorder, window)
    }

    /// The other half of the mechanism, and the half that had no test at all:
    /// when the delegate declines, the *window* is the one that closes. That
    /// is what makes ⌘W on the last terminal do the right thing, and deleting
    /// the fall-through used to fail nothing.
    func testDecliningHandsTheCloseToTheWindow() throws {
        let (view, recorder, window) = try closableSurface()
        defer { tearDown(view, window) }
        recorder.closesPane = false
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible, "precondition: the window is on screen")

        view.performClose(nil)

        XCTAssertFalse(window.isVisible, "the window was never asked to close")
    }

    /// ...and when the pane took it, the window stays. Three unsplit tabs and
    /// a ⌘W that closed the window with them is issue #41 itself.
    func testAClosedPaneLeavesTheWindowAlone() throws {
        let (view, recorder, window) = try closableSurface()
        defer { tearDown(view, window) }
        recorder.closesPane = true
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)

        view.performClose(nil)

        XCTAssertTrue(window.isVisible, "closing a pane took the whole window with it")
    }

    // MARK: - Keyboard scrollback
    //
    // ⌘Home/⌘End/⌘PgUp/⌘PgDn move the viewport. They are taken in `keyDown`
    // before `KeyTranslation` and the encoder, so nothing about them reaches
    // the PTY — the same rule the wheel's viewport half follows. Without ⌘
    // the identical keys belong to the program.

    private func fill(_ engine: TerminalEngine, lines: Int = 300) {
        var text = ""
        for i in 0..<lines { text += "line \(i)\r\n" }
        write(engine, text)
    }

    /// The Unicode private-use characters AppKit puts in `characters` for the
    /// navigation keys, so these events are the ones a real keyboard sends.
    private enum FunctionKey {
        static let home = "\u{F729}"
        static let end = "\u{F72B}"
        static let pageUp = "\u{F72C}"
        static let pageDown = "\u{F72D}"
    }

    func testCommandHomeAndEndJumpTheViewport() throws {
        let (view, engine, recorder) = try surface()
        fill(engine)

        view.keyDown(
            with: try XCTUnwrap(
                keyDown(kVK_Home, characters: FunctionKey.home, mods: .command)))
        XCTAssertEqual(engine.scrollbar.offset, 0)
        XCTAssertTrue(recorder.sent.isEmpty, "a viewport chord reached the PTY")

        view.keyDown(
            with: try XCTUnwrap(
                keyDown(kVK_End, characters: FunctionKey.end, mods: .command)))
        let bar = engine.scrollbar
        XCTAssertEqual(bar.offset + bar.length, bar.total)
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    /// A page is a screen less one row — the overlap every pager keeps.
    func testCommandPageKeysMoveByAScreen() throws {
        let (view, engine, recorder) = try surface()
        fill(engine)
        let bottom = engine.scrollbar.offset
        let page = UInt64(engine.rows - 1)

        view.keyDown(
            with: try XCTUnwrap(
                keyDown(kVK_PageUp, characters: FunctionKey.pageUp, mods: .command)))
        XCTAssertEqual(engine.scrollbar.offset, bottom - page)

        view.keyDown(
            with: try XCTUnwrap(
                keyDown(kVK_PageDown, characters: FunctionKey.pageDown, mods: .command)))
        XCTAssertEqual(engine.scrollbar.offset, bottom)

        XCTAssertTrue(recorder.sent.isEmpty)
    }

    /// The regression that matters: plain Home and PgUp are the program's.
    /// `less` gets its own page keys, and the viewport does not move behind it.
    func testPlainNavigationKeysStillReachTheProgram() throws {
        let (view, engine, recorder) = try surface()
        fill(engine)
        let before = engine.scrollbar.offset

        view.keyDown(with: try XCTUnwrap(keyDown(kVK_Home, characters: FunctionKey.home)))
        view.keyDown(with: try XCTUnwrap(keyDown(kVK_PageUp, characters: FunctionKey.pageUp)))

        XCTAssertEqual(recorder.sent.count, 2, "the program was not told about its own keys")
        XCTAssertFalse(recorder.bytes.isEmpty)
        XCTAssertEqual(
            engine.scrollbar.offset, before, "the viewport moved on a key it does not own")
    }

    /// And nothing leaks under the Kitty protocol, which is the case the
    /// interception order exists for: with event reporting on, even a key-up
    /// produces bytes, so a chord swallowed on the way down has to be
    /// swallowed on the way up too.
    ///
    /// The plain key-up at the end is a positive control. Without it this test
    /// would still pass if `CSI > 11 u` ever stopped enabling event reporting,
    /// or if the encoder stopped emitting releases — an "asserts nothing"
    /// green.
    func testViewportChordsAreInvisibleToAKittyProtocolProgram() throws {
        let (view, engine, recorder) = try surface()
        fill(engine)
        // disambiguate | report_events | report_all
        write(engine, "\u{1b}[>11u")

        view.keyDown(
            with: try XCTUnwrap(
                keyDown(kVK_Home, characters: FunctionKey.home, mods: .command)))
        view.keyUp(
            with: try XCTUnwrap(
                keyDown(
                    kVK_Home, characters: FunctionKey.home, mods: .command, type: .keyUp)))

        XCTAssertTrue(recorder.sent.isEmpty, "the program saw a key the viewport took")
        XCTAssertEqual(engine.scrollbar.offset, 0)

        // The control: the same key with no ⌘ belongs to the program, and its
        // release really does produce bytes under this mode.
        view.keyUp(
            with: try XCTUnwrap(
                keyDown(kVK_Home, characters: FunctionKey.home, type: .keyUp)))
        XCTAssertFalse(
            recorder.sent.isEmpty,
            "event reporting is off, so the assertion above proved nothing")
    }

    /// Letting go of ⌘ before the key — the ordinary way anyone releases a
    /// chord — used to put `ESC[1;1:3H` on the wire for a press the program
    /// never saw, because the key-up re-derived "was this a chord?" from the
    /// modifiers it happened to carry.
    func testReleasingCommandFirstDoesNotLeakTheKeyUp() throws {
        let (view, engine, recorder) = try surface()
        fill(engine)
        write(engine, "\u{1b}[>11u")

        view.keyDown(
            with: try XCTUnwrap(
                keyDown(kVK_Home, characters: FunctionKey.home, mods: .command)))
        // ⌘ is already up by the time Home is released.
        view.keyUp(
            with: try XCTUnwrap(
                keyDown(kVK_Home, characters: FunctionKey.home, type: .keyUp)))

        XCTAssertTrue(
            recorder.sent.isEmpty,
            "a release leaked for a press the program never saw: \(recorder.text.debugDescription)"
        )
    }

    /// And the mirror. Home pressed alone reaches the program; pressing ⌘
    /// while still holding it must not make the release look like a chord and
    /// swallow the end of a keystroke the program was told about.
    func testPressingCommandMidKeystrokeDoesNotSwallowTheRelease() throws {
        let (view, engine, recorder) = try surface()
        fill(engine)
        write(engine, "\u{1b}[>11u")

        view.keyDown(with: try XCTUnwrap(keyDown(kVK_Home, characters: FunctionKey.home)))
        let afterPress = recorder.sent.count
        XCTAssertGreaterThan(afterPress, 0, "the press was the program's")

        view.keyUp(
            with: try XCTUnwrap(
                keyDown(
                    kVK_Home, characters: FunctionKey.home, mods: .command, type: .keyUp)))

        XCTAssertGreaterThan(
            recorder.sent.count, afterPress, "the program was left holding a key it never released")
    }

    /// ⌘ **and nothing else**. `contains(.command)` also matched ⇧⌘Home —
    /// macOS's "extend selection to the top of the document" — and ⌥⌘Home and
    /// ⌃⌘End, which Helix, kakoune and neovim bind under the Kitty protocol.
    /// All three were being eaten by the viewport.
    func testOtherModifiersWithCommandBelongToTheProgram() throws {
        let cases: [(String, Int, String, NSEvent.ModifierFlags)] = [
            ("⇧⌘Home", kVK_Home, FunctionKey.home, [.command, .shift]),
            ("⌥⌘Home", kVK_Home, FunctionKey.home, [.command, .option]),
            ("⌃⌘End", kVK_End, FunctionKey.end, [.command, .control]),
        ]
        for (name, code, characters, mods) in cases {
            let (view, engine, recorder) = try surface()
            fill(engine)
            write(engine, "\u{1b}[>11u")
            let before = engine.scrollbar.offset

            view.keyDown(
                with: try XCTUnwrap(keyDown(code, characters: characters, mods: mods)))

            XCTAssertEqual(
                engine.scrollbar.offset, before, "\(name) moved the viewport")
            XCTAssertFalse(recorder.sent.isEmpty, "\(name) was eaten instead of encoded")
        }
    }

    /// On the alternate screen — `vim`, `less`, `htop` — there is no
    /// scrollback, so claiming the chord would make it a dead key: a keystroke
    /// eaten for nothing. It falls through to the program instead.
    func testTheChordsAreNotClaimedWhereThereIsNothingToScroll() throws {
        let (view, engine, recorder) = try surface()
        fill(engine)
        write(engine, "\u{1b}[?1049h")
        XCTAssertFalse(engine.scrollbar.canScroll, "the premise: no scrollback here")

        view.keyDown(
            with: try XCTUnwrap(
                keyDown(kVK_PageUp, characters: FunctionKey.pageUp, mods: .command)))

        XCTAssertFalse(recorder.sent.isEmpty, "⌘PgUp was swallowed and did nothing at all")
    }

    /// A scroll the user cannot see happen is half a feature: the position
    /// indicator comes up with the keyboard exactly as it does with the wheel.
    func testAChordShowsTheScrollbar() throws {
        let (view, engine, _) = try surface()
        fill(engine)
        XCTAssertFalse(view.isShowingScrollbarForTesting)

        view.keyDown(
            with: try XCTUnwrap(
                keyDown(kVK_PageUp, characters: FunctionKey.pageUp, mods: .command)))

        XCTAssertTrue(view.isShowingScrollbarForTesting, "the viewport moved with no indicator")
    }

    /// Shift does *not* take the wheel away from the program. Ghostty's
    /// `scrollCallback` has no shift gate — `mouseShiftCapture` is consulted
    /// for clicks and motion and nowhere else — so a shift-wheel inside a
    /// full-screen TUI is the program's, even though a shift-click is not.
    func testShiftDoesNotSuppressWheelReporting() throws {
        let (view, engine, recorder) = try surface()
        write(engine, "\u{1b}[?1000h\u{1b}[?1006h")

        XCTAssertTrue(view.reportWheel(rows: 1, columns: 0, mods: [.shift], at: .zero))
        XCTAssertEqual(recorder.sent.count, 1)
        // Shift rides along in the report rather than cancelling it: SGR
        // button 64 plus 4 for shift.
        XCTAssertTrue(String(decoding: recorder.bytes, as: UTF8.self).hasPrefix("\u{1b}[<68;"))
    }

    /// Shift *does* take a click away from the program, which is what lets
    /// you select text inside one.
    func testShiftSuppressesButtonReporting() throws {
        let (view, engine, recorder) = try surface()
        write(engine, "\u{1b}[?1000h\u{1b}[?1006h")

        let shiftClick = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [.shift],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        view.mouseDown(with: shiftClick)
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    /// Both wheel claimants drop the selection, as Ghostty's `scrollCallback`
    /// does. A highlight left behind while the program scrolls under it is
    /// pointing at whatever ends up in those cells.
    func testWheelClearsTheSelectionForTheProgram() throws {
        let (view, engine, _) = try surface()
        write(engine, "hello world\u{1b}[?1000h\u{1b}[?1006h")
        engine.selectAll()
        XCTAssertTrue(engine.hasSelection)

        XCTAssertTrue(view.reportWheel(rows: 1, columns: 0, mods: [], at: .zero))
        XCTAssertFalse(engine.hasSelection)
    }

    func testAlternateScrollClearsTheSelection() throws {
        let (view, engine, _) = try surface()
        // Text after the switch: select-all works on the active screen, and
        // the alternate one starts empty.
        write(engine, "\u{1b}[?1049h\u{1b}[?1007hhello")
        engine.selectAll()
        XCTAssertTrue(engine.hasSelection)

        XCTAssertTrue(view.reportWheel(rows: -1, columns: 0, mods: [], at: .zero))
        XCTAssertFalse(engine.hasSelection)
    }

    /// And a wheel nobody claims leaves it alone — that gesture belongs to the
    /// viewport, and scrolling your own view is not a reason to lose what you
    /// selected.
    func testUnclaimedWheelKeepsTheSelection() throws {
        let (view, engine, _) = try surface()
        write(engine, "hello world")
        engine.selectAll()

        XCTAssertFalse(view.reportWheel(rows: 1, columns: 0, mods: [], at: .zero))
        XCTAssertTrue(engine.hasSelection)
    }
}
