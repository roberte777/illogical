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
        var resizes: [(cols: UInt16, rows: UInt16)] = []
        var readied = false

        var bytes: [UInt8] { sent.flatMap { $0 } }
        var text: String { String(decoding: bytes, as: UTF8.self) }

        func surfaceIsReady(_ surface: TerminalSurfaceView) { readied = true }
        func surface(_ surface: TerminalSurfaceView, send bytes: [UInt8]) { sent.append(bytes) }
        func surface(_ surface: TerminalSurfaceView, resizeTo cols: UInt16, rows: UInt16) {
            resizes.append((cols, rows))
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
        _ keyCode: Int, characters: String, mods: NSEvent.ModifierFlags = []
    )
        -> NSEvent?
    {
        NSEvent.keyEvent(
            with: .keyDown,
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
}
