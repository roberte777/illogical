//  InputTests.swift
//  What the terminal's own modes do to what a key encodes to.
//
//  The point of routing input through libghostty-vt is that the answer is
//  never a fixed table: the same arrow key is `ESC [ A` or `ESC O A` depending
//  on DECCKM, and `escape` grows a Kitty suffix the moment a program pushes
//  the disambiguate flag. These tests drive a real terminal, set the mode
//  with the same escape sequence a program would, and check the bytes change.

import AppKit
import Carbon.HIToolbox
import GhosttyVt
import XCTest

@MainActor
final class InputTests: XCTestCase {
    private func engine(cols: UInt16 = 80, rows: UInt16 = 24) throws -> TerminalEngine {
        try TerminalEngine(cols: cols, rows: rows)
    }

    private func write(_ engine: TerminalEngine, _ text: String) {
        var bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { engine.write(UnsafeRawBufferPointer($0)) }
    }

    private func key(
        _ key: GhosttyKey,
        mods: GhosttyMods = 0,
        text: String? = nil,
        unshifted: UInt32 = 0,
        action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS
    ) -> KeyEventSpec {
        KeyEventSpec(
            action: action,
            key: key,
            mods: mods,
            consumedMods: mods & ~(UInt16(GHOSTTY_MODS_CTRL) | UInt16(GHOSTTY_MODS_SUPER)),
            text: text,
            unshiftedCodepoint: unshifted)
    }

    private func string(_ bytes: [UInt8]?) -> String? {
        guard let bytes else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Keys

    func testPlainKeysEncodeTheirText() throws {
        let engine = try engine()
        let encoder = try InputEncoder(engine: engine)

        XCTAssertEqual(string(encoder.encode(key: key(GHOSTTY_KEY_ENTER))), "\r")
        XCTAssertEqual(string(encoder.encode(key: key(GHOSTTY_KEY_TAB))), "\t")
        XCTAssertEqual(string(encoder.encode(key: key(GHOSTTY_KEY_BACKSPACE))), "\u{7f}")
        XCTAssertEqual(string(encoder.encode(key: key(GHOSTTY_KEY_ESCAPE))), "\u{1b}")
        XCTAssertEqual(
            string(encoder.encode(key: key(GHOSTTY_KEY_A, text: "a", unshifted: 0x61))), "a")
    }

    /// Control characters are derived from the logical key, not from the text
    /// AppKit produced — which is why `text` is allowed to be the unmodified
    /// character.
    func testControlSequences() throws {
        let engine = try engine()
        let encoder = try InputEncoder(engine: engine)

        let ctrl = UInt16(GHOSTTY_MODS_CTRL)
        XCTAssertEqual(
            encoder.encode(key: key(GHOSTTY_KEY_A, mods: ctrl, text: "a", unshifted: 0x61)),
            [0x01])
        XCTAssertEqual(
            encoder.encode(key: key(GHOSTTY_KEY_C, mods: ctrl, text: "c", unshifted: 0x63)),
            [0x03])
        XCTAssertEqual(
            encoder.encode(key: key(GHOSTTY_KEY_SPACE, mods: ctrl, text: " ", unshifted: 0x20)),
            [0x00])
    }

    /// DECCKM. The same key, two answers, and the difference is terminal
    /// state we would otherwise have had to track ourselves.
    func testCursorKeyApplicationMode() throws {
        let engine = try engine()
        let encoder = try InputEncoder(engine: engine)

        XCTAssertEqual(string(encoder.encode(key: key(GHOSTTY_KEY_ARROW_UP))), "\u{1b}[A")
        write(engine, "\u{1b}[?1h")
        XCTAssertEqual(string(encoder.encode(key: key(GHOSTTY_KEY_ARROW_UP))), "\u{1b}OA")
        write(engine, "\u{1b}[?1l")
        XCTAssertEqual(string(encoder.encode(key: key(GHOSTTY_KEY_ARROW_UP))), "\u{1b}[A")
    }

    /// Modified arrows carry a modifier parameter, which the hand-rolled
    /// subset this replaces did not encode at all.
    func testModifiedArrows() throws {
        let engine = try engine()
        let encoder = try InputEncoder(engine: engine)

        XCTAssertEqual(
            string(
                encoder.encode(key: key(GHOSTTY_KEY_ARROW_RIGHT, mods: UInt16(GHOSTTY_MODS_SHIFT)))),
            "\u{1b}[1;2C")
        XCTAssertEqual(
            string(
                encoder.encode(key: key(GHOSTTY_KEY_ARROW_LEFT, mods: UInt16(GHOSTTY_MODS_CTRL)))),
            "\u{1b}[1;5D")
    }

    /// The Kitty keyboard protocol, pushed by the program the way a real one
    /// does it. Escape stops being one byte.
    func testKittyKeyboardProtocol() throws {
        let engine = try engine()
        let encoder = try InputEncoder(engine: engine)

        XCTAssertEqual(string(encoder.encode(key: key(GHOSTTY_KEY_ESCAPE))), "\u{1b}")
        write(engine, "\u{1b}[>1u")
        XCTAssertEqual(string(encoder.encode(key: key(GHOSTTY_KEY_ESCAPE))), "\u{1b}[27u")
        write(engine, "\u{1b}[<u")
        XCTAssertEqual(string(encoder.encode(key: key(GHOSTTY_KEY_ESCAPE))), "\u{1b}")
    }

    /// A key release produces nothing until the program asks for releases,
    /// which is the entire reason to send them to the encoder rather than
    /// dropping them here.
    func testReleasesOnlyWhenReported() throws {
        let engine = try engine()
        let encoder = try InputEncoder(engine: engine)

        let release = key(GHOSTTY_KEY_A, unshifted: 0x61, action: GHOSTTY_KEY_ACTION_RELEASE)
        XCTAssertNil(encoder.encode(key: release))

        // Disambiguate plus report-events.
        write(engine, "\u{1b}[>3u")
        XCTAssertNotNil(encoder.encode(key: release))
    }

    // MARK: - Mouse

    private func mouseEncoder(_ engine: TerminalEngine) throws -> InputEncoder {
        let encoder = try InputEncoder(engine: engine)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = 800
        size.screen_height = 400
        size.cell_width = 8
        size.cell_height = 16
        encoder.surfaceSize = size
        return encoder
    }

    func testMouseIsSilentUntilRequested() throws {
        let engine = try engine()
        let encoder = try mouseEncoder(engine)

        XCTAssertFalse(encoder.mouseTrackingEnabled)
        XCTAssertNil(
            encoder.encode(
                mouse: MouseEventSpec(
                    action: GHOSTTY_MOUSE_ACTION_PRESS,
                    button: GHOSTTY_MOUSE_BUTTON_LEFT,
                    mods: 0,
                    position: GhosttyMousePosition(x: 12, y: 20))))
    }

    /// Mode 1000 turns reporting on, 1006 asks for SGR. A press at pixel
    /// (12, 20) with 8x16 cells is column 1, row 1, and the protocol is
    /// one-based.
    func testSGRMouseReport() throws {
        let engine = try engine()
        let encoder = try mouseEncoder(engine)
        write(engine, "\u{1b}[?1000h\u{1b}[?1006h")

        XCTAssertTrue(encoder.mouseTrackingEnabled)
        let press = MouseEventSpec(
            action: GHOSTTY_MOUSE_ACTION_PRESS,
            button: GHOSTTY_MOUSE_BUTTON_LEFT,
            mods: 0,
            position: GhosttyMousePosition(x: 12, y: 20))
        XCTAssertEqual(string(encoder.encode(mouse: press)), "\u{1b}[<0;2;2M")

        var release = press
        release.action = GHOSTTY_MOUSE_ACTION_RELEASE
        XCTAssertEqual(string(encoder.encode(mouse: release)), "\u{1b}[<0;2;2m")
    }

    /// Wheel up is button four, which is how every mouse protocol since X10
    /// has spelled scroll.
    func testWheelIsAButton() throws {
        let engine = try engine()
        let encoder = try mouseEncoder(engine)
        write(engine, "\u{1b}[?1000h\u{1b}[?1006h")

        let up = MouseEventSpec(
            action: GHOSTTY_MOUSE_ACTION_PRESS,
            button: GHOSTTY_MOUSE_BUTTON_FOUR,
            mods: 0,
            position: GhosttyMousePosition(x: 0, y: 0))
        XCTAssertEqual(string(encoder.encode(mouse: up)), "\u{1b}[<64;1;1M")
    }

    // MARK: - Focus

    func testFocusReportsOnlyUnderMode1004() throws {
        let engine = try engine()
        let encoder = try InputEncoder(engine: engine)

        XCTAssertNil(encoder.encodeFocus(gained: true))
        write(engine, "\u{1b}[?1004h")
        XCTAssertEqual(string(encoder.encodeFocus(gained: true)), "\u{1b}[I")
        XCTAssertEqual(string(encoder.encodeFocus(gained: false)), "\u{1b}[O")
        write(engine, "\u{1b}[?1004l")
        XCTAssertNil(encoder.encodeFocus(gained: false))
    }

    // MARK: - Translation

    func testKeycodeTable() {
        XCTAssertEqual(KeyTranslation.key(forKeycode: kVK_ANSI_A), GHOSTTY_KEY_A)
        XCTAssertEqual(KeyTranslation.key(forKeycode: kVK_Return), GHOSTTY_KEY_ENTER)
        XCTAssertEqual(KeyTranslation.key(forKeycode: kVK_Delete), GHOSTTY_KEY_BACKSPACE)
        XCTAssertEqual(KeyTranslation.key(forKeycode: kVK_ForwardDelete), GHOSTTY_KEY_DELETE)
        XCTAssertEqual(KeyTranslation.key(forKeycode: kVK_UpArrow), GHOSTTY_KEY_ARROW_UP)
        XCTAssertEqual(KeyTranslation.key(forKeycode: kVK_F13), GHOSTTY_KEY_F13)
        // macOS puts Help where a PC keyboard has Insert.
        XCTAssertEqual(KeyTranslation.key(forKeycode: kVK_Help), GHOSTTY_KEY_INSERT)
        // And Clear where it has Num Lock.
        XCTAssertEqual(KeyTranslation.key(forKeycode: kVK_ANSI_KeypadClear), GHOSTTY_KEY_NUM_LOCK)
        XCTAssertNil(KeyTranslation.key(forKeycode: 0xff))
    }

    /// Every key in the table is distinct. A duplicate would silently make
    /// two physical keys encode as one.
    func testKeycodeTableHasNoCollisions() {
        var seen: [Int32: Int] = [:]
        for keycode in 0..<0x80 {
            guard let key = KeyTranslation.key(forKeycode: keycode) else { continue }
            XCTAssertNil(
                seen[key.rawValue], "keycode \(keycode) collides with \(seen[key.rawValue]!)")
            seen[key.rawValue] = keycode
        }
        XCTAssertGreaterThan(seen.count, 100)
    }

    func testModifierTranslation() {
        XCTAssertEqual(KeyTranslation.mods([]), 0)
        XCTAssertEqual(
            KeyTranslation.mods([.shift]) & UInt16(GHOSTTY_MODS_SHIFT), UInt16(GHOSTTY_MODS_SHIFT))
        XCTAssertEqual(
            KeyTranslation.mods([.control]) & UInt16(GHOSTTY_MODS_CTRL), UInt16(GHOSTTY_MODS_CTRL))
        XCTAssertEqual(
            KeyTranslation.mods([.option]) & UInt16(GHOSTTY_MODS_ALT), UInt16(GHOSTTY_MODS_ALT))
        XCTAssertEqual(
            KeyTranslation.mods([.command]) & UInt16(GHOSTTY_MODS_SUPER), UInt16(GHOSTTY_MODS_SUPER)
        )
        // `.numericPad` is "came from the keypad", not num lock, and must not
        // be reported as a modifier at all.
        XCTAssertEqual(KeyTranslation.mods([.numericPad]), 0)

        // Sidedness rides in the device-dependent bits, which is the only
        // place AppKit puts it.
        let rightShift = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x04)
        XCTAssertEqual(
            KeyTranslation.mods(rightShift) & UInt16(GHOSTTY_MODS_SHIFT_SIDE),
            UInt16(GHOSTTY_MODS_SHIFT_SIDE))
        XCTAssertEqual(KeyTranslation.mods([.shift]) & UInt16(GHOSTTY_MODS_SHIFT_SIDE), 0)
    }

    /// `ghostty_key_event_set_utf8` refuses C0, DEL and the function-key PUA
    /// block: the encoder derives those from the logical key, and passing
    /// them would encode the key twice.
    func testTextRejectsControlAndFunctionKeys() throws {
        let arrowUp = try XCTUnwrap(
            synthesize(keyCode: UInt16(kVK_UpArrow), characters: "\u{f700}"))
        XCTAssertNil(KeyTranslation.text(for: arrowUp))
        XCTAssertEqual(KeyTranslation.unshiftedCodepoint(for: arrowUp), 0)

        let backspace = try XCTUnwrap(
            synthesize(keyCode: UInt16(kVK_Delete), characters: "\u{7f}"))
        XCTAssertNil(KeyTranslation.text(for: backspace))

        let plain = try XCTUnwrap(synthesize(keyCode: UInt16(kVK_ANSI_A), characters: "a"))
        XCTAssertEqual(KeyTranslation.text(for: plain), "a")
    }

    func testSpecFromEvent() throws {
        let event = try XCTUnwrap(synthesize(keyCode: UInt16(kVK_ANSI_A), characters: "a"))
        let spec = try XCTUnwrap(KeyTranslation.spec(for: event))
        XCTAssertEqual(spec.key, GHOSTTY_KEY_A)
        XCTAssertEqual(spec.action, GHOSTTY_KEY_ACTION_PRESS)

        let unknown = try XCTUnwrap(synthesize(keyCode: 0xfe, characters: "x"))
        XCTAssertNil(KeyTranslation.spec(for: unknown))
    }

    private func synthesize(keyCode: UInt16, characters: String) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode)
    }
}
