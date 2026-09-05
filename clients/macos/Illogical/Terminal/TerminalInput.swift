//  TerminalInput.swift
//  Key and mouse encoding, done by libghostty rather than by hand.
//
//  The first version of this was a switch statement over `keyCode` that covered
//  the arrows, Return, Tab and Ctrl-letter. That is enough to use a shell and
//  not much more: no Kitty keyboard protocol, no modifyOtherKeys, no correct
//  Alt handling, no mouse reporting at all. libghostty already implements all
//  of it, and — critically — the *server's* terminal is the thing whose modes
//  decide the encoding, so encoding it ourselves would drift from the
//  authoritative state on every mode change.
//
//  `setopt_from_terminal` reads those modes off our replica, which the server
//  keeps in step, so the encoders follow the running program automatically.

import AppKit
import Carbon.HIToolbox
import GhosttyVt

/// Maps AppKit key events onto libghostty's key encoder.
final class KeyEncoder {
    private var encoder: GhosttyKeyEncoder?
    private var event: GhosttyKeyEvent?

    init?() {
        var encoder: GhosttyKeyEncoder?
        guard ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS else { return nil }
        var event: GhosttyKeyEvent?
        guard ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS else {
            ghostty_key_encoder_free(encoder)
            return nil
        }
        self.encoder = encoder
        self.event = event
    }

    deinit {
        if let event { ghostty_key_event_free(event) }
        if let encoder { ghostty_key_encoder_free(encoder) }
    }

    /// Encode `nsEvent` against `terminal`'s current modes.
    func encode(
        _ nsEvent: NSEvent, terminal: GhosttyTerminal, action: GhosttyKeyAction
    )
        -> [UInt8]?
    {
        guard let encoder, let event else { return nil }
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)

        ghostty_key_event_set_action(event, action)
        ghostty_key_event_set_key(event, Self.key(for: nsEvent))
        ghostty_key_event_set_mods(event, KeyEncoderBridge.mods(for: nsEvent.modifierFlags))
        ghostty_key_event_set_composing(event, false)

        // The text the key would produce, and the unmodified codepoint the
        // Kitty protocol reports. Both come from AppKit, not from our guesses.
        let text = nsEvent.characters ?? ""
        var bytes = Array(text.utf8)
        if bytes.isEmpty {
            ghostty_key_event_set_utf8(event, nil, 0)
        } else {
            bytes.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                    ghostty_key_event_set_utf8(event, $0, buffer.count)
                }
            }
        }
        if let scalar = nsEvent.charactersIgnoringModifiers?.unicodeScalars.first {
            ghostty_key_event_set_unshifted_codepoint(event, scalar.value)
        }

        var out = [CChar](repeating: 0, count: 128)
        var written = 0
        let result = out.withUnsafeMutableBufferPointer { buffer in
            ghostty_key_encoder_encode(encoder, event, buffer.baseAddress, buffer.count, &written)
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return out.prefix(written).map { UInt8(bitPattern: $0) }
    }

    /// AppKit virtual key codes are positional, so this is a table rather than
    /// anything derivable. Unlisted keys fall through to UNIDENTIFIED, which
    /// libghostty encodes from the event's UTF-8 instead.
    private static func key(for event: NSEvent) -> GhosttyKey {
        switch Int(event.keyCode) {
        case kVK_ANSI_A: GHOSTTY_KEY_A
        case kVK_ANSI_B: GHOSTTY_KEY_B
        case kVK_ANSI_C: GHOSTTY_KEY_C
        case kVK_ANSI_D: GHOSTTY_KEY_D
        case kVK_ANSI_E: GHOSTTY_KEY_E
        case kVK_ANSI_F: GHOSTTY_KEY_F
        case kVK_ANSI_G: GHOSTTY_KEY_G
        case kVK_ANSI_H: GHOSTTY_KEY_H
        case kVK_ANSI_I: GHOSTTY_KEY_I
        case kVK_ANSI_J: GHOSTTY_KEY_J
        case kVK_ANSI_K: GHOSTTY_KEY_K
        case kVK_ANSI_L: GHOSTTY_KEY_L
        case kVK_ANSI_M: GHOSTTY_KEY_M
        case kVK_ANSI_N: GHOSTTY_KEY_N
        case kVK_ANSI_O: GHOSTTY_KEY_O
        case kVK_ANSI_P: GHOSTTY_KEY_P
        case kVK_ANSI_Q: GHOSTTY_KEY_Q
        case kVK_ANSI_R: GHOSTTY_KEY_R
        case kVK_ANSI_S: GHOSTTY_KEY_S
        case kVK_ANSI_T: GHOSTTY_KEY_T
        case kVK_ANSI_U: GHOSTTY_KEY_U
        case kVK_ANSI_V: GHOSTTY_KEY_V
        case kVK_ANSI_W: GHOSTTY_KEY_W
        case kVK_ANSI_X: GHOSTTY_KEY_X
        case kVK_ANSI_Y: GHOSTTY_KEY_Y
        case kVK_ANSI_Z: GHOSTTY_KEY_Z
        case kVK_Return: GHOSTTY_KEY_ENTER
        case kVK_Tab: GHOSTTY_KEY_TAB
        case kVK_Space: GHOSTTY_KEY_SPACE
        case kVK_Delete: GHOSTTY_KEY_BACKSPACE
        case kVK_ForwardDelete: GHOSTTY_KEY_DELETE
        case kVK_Escape: GHOSTTY_KEY_ESCAPE
        case kVK_UpArrow: GHOSTTY_KEY_ARROW_UP
        case kVK_DownArrow: GHOSTTY_KEY_ARROW_DOWN
        case kVK_LeftArrow: GHOSTTY_KEY_ARROW_LEFT
        case kVK_RightArrow: GHOSTTY_KEY_ARROW_RIGHT
        case kVK_Home: GHOSTTY_KEY_HOME
        case kVK_End: GHOSTTY_KEY_END
        case kVK_PageUp: GHOSTTY_KEY_PAGE_UP
        case kVK_PageDown: GHOSTTY_KEY_PAGE_DOWN
        case kVK_F1: GHOSTTY_KEY_F1
        case kVK_F2: GHOSTTY_KEY_F2
        case kVK_F3: GHOSTTY_KEY_F3
        case kVK_F4: GHOSTTY_KEY_F4
        case kVK_F5: GHOSTTY_KEY_F5
        case kVK_F6: GHOSTTY_KEY_F6
        case kVK_F7: GHOSTTY_KEY_F7
        case kVK_F8: GHOSTTY_KEY_F8
        case kVK_F9: GHOSTTY_KEY_F9
        case kVK_F10: GHOSTTY_KEY_F10
        case kVK_F11: GHOSTTY_KEY_F11
        case kVK_F12: GHOSTTY_KEY_F12
        default: GHOSTTY_KEY_UNIDENTIFIED
        }
    }
}

/// Maps AppKit mouse events onto libghostty's mouse encoder, so programs that
/// ask for mouse reporting actually get it.
final class MouseEncoder {
    private var encoder: GhosttyMouseEncoder?
    private var event: GhosttyMouseEvent?

    init?() {
        var encoder: GhosttyMouseEncoder?
        guard ghostty_mouse_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS else { return nil }
        var event: GhosttyMouseEvent?
        guard ghostty_mouse_event_new(nil, &event) == GHOSTTY_SUCCESS else {
            ghostty_mouse_encoder_free(encoder)
            return nil
        }
        self.encoder = encoder
        self.event = event
    }

    deinit {
        if let event { ghostty_mouse_event_free(event) }
        if let encoder { ghostty_mouse_encoder_free(encoder) }
    }

    func encode(
        terminal: GhosttyTerminal,
        button: GhosttyMouseButton,
        action: GhosttyMouseAction,
        mods: NSEvent.ModifierFlags,
        column: UInt16,
        row: UInt16
    ) -> [UInt8]? {
        // libghostty takes a pixel-ish position and derives the cell itself,
        // so pass cell coordinates as the position's x/y.
        guard let encoder, let event else { return nil }
        ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal)

        ghostty_mouse_event_set_button(event, button)
        ghostty_mouse_event_set_action(event, action)
        ghostty_mouse_event_set_mods(event, KeyEncoderBridge.mods(for: mods))
        var position = GhosttyMousePosition()
        position.x = Float(column)
        position.y = Float(row)
        ghostty_mouse_event_set_position(event, position)

        var out = [CChar](repeating: 0, count: 64)
        var written = 0
        let result = out.withUnsafeMutableBufferPointer { buffer in
            ghostty_mouse_encoder_encode(encoder, event, buffer.baseAddress, buffer.count, &written)
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return out.prefix(written).map { UInt8(bitPattern: $0) }
    }
}

/// Shared modifier translation. Both encoders take the same `GhosttyMods`.
enum KeyEncoderBridge {
    static func mods(for flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= UInt32(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { mods |= UInt32(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option) { mods |= UInt32(GHOSTTY_MODS_ALT) }
        if flags.contains(.command) { mods |= UInt32(GHOSTTY_MODS_SUPER) }
        if flags.contains(.capsLock) { mods |= UInt32(GHOSTTY_MODS_CAPS_LOCK) }
        return GhosttyMods(mods)
    }
}
