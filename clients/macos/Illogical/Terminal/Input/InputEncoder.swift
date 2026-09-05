//  InputEncoder.swift
//  Key, mouse and focus events → the bytes a PTY expects.
//
//  Every sequence in here comes out of libghostty-vt. That matters more than
//  it looks: what a key encodes to depends on terminal state the client does
//  not otherwise model — DECCKM, DECNKM, `modifyOtherKeys`, and the five
//  independent Kitty keyboard flags, each of which can be pushed and popped
//  by the program running in the terminal. A hand-rolled table gets the
//  common cases right and then silently disagrees with the shell about
//  ctrl+shift+enter forever. See docs/CLIENT.md.
//
//  The encoders are stateful and configured from the terminal immediately
//  before each encode, under the engine's lock, so the modes they encode
//  against are the modes the terminal actually has. Encoding writes into a
//  stack buffer and takes well under a microsecond; holding the lock across
//  it is cheaper than sampling the modes and racing the reader thread.

import AppKit
import Carbon.HIToolbox
import GhosttyVt

/// One mouse event, in the terms libghostty-vt's encoder takes.
struct MouseEventSpec {
    var action: GhosttyMouseAction
    /// Nil for motion with no button held. Wheel "buttons" are four through
    /// seven, which is how every mouse protocol since X10 has spelled scroll.
    var button: GhosttyMouseButton?
    var mods: GhosttyMods
    /// Surface pixels, (0, 0) at the top-left of the view, padding included.
    var position: GhosttyMousePosition
}

/// The four libghostty handles, in a box that can free itself.
///
/// `InputEncoder` is main-actor bound and a nonisolated `deinit` may not
/// touch main-actor state, so ownership of the handles lives here instead.
/// Nothing outside the encoder ever sees this object, and the encoder only
/// runs on the main actor, which is what makes the unchecked conformance
/// true rather than merely convenient.
private final class EncoderHandles: @unchecked Sendable {
    var keyEncoder: GhosttyKeyEncoder?
    var keyEvent: GhosttyKeyEvent?
    var mouseEncoder: GhosttyMouseEncoder?
    var mouseEvent: GhosttyMouseEvent?

    deinit {
        if let keyEvent { ghostty_key_event_free(keyEvent) }
        if let keyEncoder { ghostty_key_encoder_free(keyEncoder) }
        if let mouseEvent { ghostty_mouse_event_free(mouseEvent) }
        if let mouseEncoder { ghostty_mouse_encoder_free(mouseEncoder) }
    }
}

@MainActor
final class InputEncoder {
    private let engine: TerminalEngine
    private let handles = EncoderHandles()

    /// Surface geometry, in device pixels. The encoder turns a pixel
    /// position into a cell itself, so this has to track the renderer.
    var surfaceSize = GhosttyMouseEncoderSize()
    /// Whether any button is down, which changes what a motion event encodes
    /// to under button-tracking mode.
    var anyButtonPressed = false

    init(engine: TerminalEngine) throws {
        self.engine = engine

        try check("ghostty_key_encoder_new") { ghostty_key_encoder_new(nil, &handles.keyEncoder) }
        try check("ghostty_key_event_new") { ghostty_key_event_new(nil, &handles.keyEvent) }
        try check("ghostty_mouse_encoder_new") {
            ghostty_mouse_encoder_new(nil, &handles.mouseEncoder)
        }
        try check("ghostty_mouse_event_new") { ghostty_mouse_event_new(nil, &handles.mouseEvent) }

        surfaceSize.size = MemoryLayout<GhosttyMouseEncoderSize>.size
    }

    // MARK: - Keys

    /// Encode one key event. Nil when the key produces nothing, which is the
    /// normal answer for a bare modifier or a release in legacy mode.
    func encode(key spec: KeyEventSpec) -> [UInt8]? {
        guard let keyEncoder = handles.keyEncoder, let keyEvent = handles.keyEvent else {
            return nil
        }

        ghostty_key_event_set_action(keyEvent, spec.action)
        ghostty_key_event_set_key(keyEvent, spec.key)
        ghostty_key_event_set_mods(keyEvent, spec.mods)
        ghostty_key_event_set_consumed_mods(keyEvent, spec.consumedMods)
        ghostty_key_event_set_composing(keyEvent, false)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, spec.unshiftedCodepoint)

        return engine.withTerminal { terminal -> [UInt8]? in
            ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal)
            var optionAsAlt = KeyboardLayout.optionAsAlt
            ghostty_key_encoder_setopt(
                keyEncoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt)

            // The event does not copy the text, so it has to stay alive
            // across the encode and be cleared before this scope ends.
            guard var text = spec.text else {
                ghostty_key_event_set_utf8(keyEvent, nil, 0)
                return Self.encodeKey(keyEncoder, keyEvent)
            }
            return text.withUTF8 { buffer -> [UInt8]? in
                buffer.withMemoryRebound(to: CChar.self) { chars in
                    ghostty_key_event_set_utf8(keyEvent, chars.baseAddress, chars.count)
                }
                defer { ghostty_key_event_set_utf8(keyEvent, nil, 0) }
                return Self.encodeKey(keyEncoder, keyEvent)
            }
        }
    }

    private static func encodeKey(
        _ encoder: GhosttyKeyEncoder, _ event: GhosttyKeyEvent
    ) -> [UInt8]? {
        withBuffer { buf, cap, len in
            ghostty_key_encoder_encode(encoder, event, buf, cap, &len)
        }
    }

    // MARK: - Mouse

    /// Encode one mouse event, or nil when the terminal is not asking for
    /// mouse reports or the event does not produce one (a motion inside the
    /// cell it was already in, say).
    func encode(mouse spec: MouseEventSpec) -> [UInt8]? {
        guard let mouseEncoder = handles.mouseEncoder, let mouseEvent = handles.mouseEvent
        else { return nil }

        ghostty_mouse_event_set_action(mouseEvent, spec.action)
        if let button = spec.button {
            ghostty_mouse_event_set_button(mouseEvent, button)
        } else {
            ghostty_mouse_event_clear_button(mouseEvent)
        }
        ghostty_mouse_event_set_mods(mouseEvent, spec.mods)
        ghostty_mouse_event_set_position(mouseEvent, spec.position)

        var size = surfaceSize
        var pressed = anyButtonPressed
        var trackLastCell = true

        return engine.withTerminal { terminal -> [UInt8]? in
            ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, terminal)
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
            ghostty_mouse_encoder_setopt(
                mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
            // Motion deduplication by cell: a mouse moved across one cell
            // generates dozens of NSEvents and at most one report.
            ghostty_mouse_encoder_setopt(
                mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackLastCell)

            return withBuffer { buf, cap, len in
                ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, buf, cap, &len)
            }
        }
    }

    /// Forget the last reported cell. Anything that moves the grid out from
    /// under the pointer — a resize, a reattach — invalidates it.
    func resetMouse() {
        guard let mouseEncoder = handles.mouseEncoder else { return }
        ghostty_mouse_encoder_reset(mouseEncoder)
    }

    // MARK: - Alternate scroll

    /// Cursor keys for a wheel gesture in the alternate screen.
    ///
    /// DECSET 1007, and only when the program is not reporting the mouse: a
    /// wheel inside `less` or `man` becomes the arrow keys they already
    /// understand. Nil when either condition does not hold, which means the
    /// gesture belongs to the viewport instead.
    ///
    /// Spelled out rather than run through the key encoder on purpose. Under
    /// the Kitty protocol the encoder would produce a Kitty sequence, and the
    /// programs alternate scroll exists for predate it — Ghostty emits the
    /// legacy cursor key here too, varying only with DECCKM.
    func encodeAlternateScroll(rows: Int) -> [UInt8]? {
        guard rows != 0 else { return nil }

        return engine.withTerminal { terminal -> [UInt8]? in
            var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
            guard
                ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
                    == GHOSTTY_SUCCESS,
                screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
            else { return nil }

            var altScroll = GhosttyTerminalModeConfig(
                mode: ghostty_mode_new(1007, false), value: false)
            guard
                ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &altScroll)
                    == GHOSTTY_SUCCESS,
                altScroll.value
            else { return nil }

            var cursorKeys = GhosttyTerminalModeConfig(
                mode: ghostty_mode_new(1, false), value: false)
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &cursorKeys)

            let sequence: String
            switch (cursorKeys.value, rows > 0) {
            case (true, true): sequence = "\u{1b}OA"
            case (true, false): sequence = "\u{1b}OB"
            case (false, true): sequence = "\u{1b}[A"
            case (false, false): sequence = "\u{1b}[B"
            }

            let one = Array(sequence.utf8)
            var out: [UInt8] = []
            out.reserveCapacity(one.count * abs(rows))
            for _ in 0..<abs(rows) { out.append(contentsOf: one) }
            return out
        }
    }

    // MARK: - Focus

    /// Encode a focus change, but only when the terminal asked for one.
    ///
    /// `ghostty_focus_encode` takes no terminal and will happily encode a
    /// report nobody wants, which a shell would then print as `[I`. DEC mode
    /// 1004 is the gate.
    func encodeFocus(gained: Bool) -> [UInt8]? {
        let wanted = engine.withTerminal { terminal -> Bool? in
            var mode = GhosttyTerminalModeConfig(
                mode: ghostty_mode_new(1004, false), value: false)
            guard
                ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode) == GHOSTTY_SUCCESS
            else { return false }
            return mode.value
        }
        guard wanted == true else { return nil }

        return withBuffer { buf, cap, len in
            ghostty_focus_encode(
                gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, buf, cap, &len)
        }
    }
}

// MARK: - Encoding into a buffer

/// Run an encode-into-a-buffer call, growing once if the stack buffer was
/// too small.
///
/// Every sequence libghostty-vt produces for a key or a mouse report fits in
/// 128 bytes with room to spare; the retry exists because the API contract
/// says it can be needed, not because we expect it.
private func withBuffer(
    _ body: (UnsafeMutablePointer<CChar>?, Int, inout Int) -> GhosttyResult
) -> [UInt8]? {
    var length = 0
    var stack = [CChar](repeating: 0, count: 128)
    let result = stack.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress, buffer.count, &length)
    }

    switch result {
    case GHOSTTY_SUCCESS:
        guard length > 0 else { return nil }
        return stack[0..<length].map { UInt8(bitPattern: $0) }

    case GHOSTTY_OUT_OF_SPACE:
        guard length > 0 else { return nil }
        var heap = [CChar](repeating: 0, count: length)
        var written = 0
        let retry = heap.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress, buffer.count, &written)
        }
        guard retry == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return heap[0..<written].map { UInt8(bitPattern: $0) }

    default:
        return nil
    }
}

// MARK: - Keyboard layout

/// Whether the option key should behave as alt.
///
/// macOS uses option to type characters — option-b is ∫ — but on a US layout
/// almost nobody wants that in a terminal; they want alt-b, the readline
/// word-back binding. Ghostty resolves this by layout, defaulting to alt on
/// the two US layouts and to text everywhere else, and we match it so a
/// German keyboard can still type `{` with option-8.
@MainActor
enum KeyboardLayout {
    private static var cached: GhosttyOptionAsAlt?
    private static var observing = false

    static var optionAsAlt: GhosttyOptionAsAlt {
        if !observing {
            observing = true
            // The layout can change while we are running, and a stale answer
            // means option stops typing what the key is labelled with.
            DistributedNotificationCenter.default.addObserver(
                forName: NSNotification.Name(
                    kTISNotifySelectedKeyboardInputSourceChanged as String),
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { cached = nil }
            }
        }
        if let cached { return cached }
        let value = detect()
        cached = value
        return value
    }

    private static func detect() -> GhosttyOptionAsAlt {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return GHOSTTY_OPTION_AS_ALT_FALSE }

        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        switch id {
        case "com.apple.keylayout.US", "com.apple.keylayout.USInternational":
            return GHOSTTY_OPTION_AS_ALT_TRUE
        default:
            return GHOSTTY_OPTION_AS_ALT_FALSE
        }
    }
}
