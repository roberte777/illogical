//  KeyTranslation.swift
//  NSEvent → the key event libghostty-vt's encoder wants.
//
//  Only two things happen here. The *physical key* comes from the macOS
//  virtual keycode, which is layout-independent: keycode 0x00 is the key
//  labelled A on a US keyboard and Q on AZERTY, and both report
//  `GHOSTTY_KEY_A`. The *text* comes from AppKit, which has already run the
//  keyboard layout, dead keys and all. Everything after that — which escape
//  sequence a key produces under which modifiers, in legacy or Kitty mode —
//  belongs to `ghostty_key_encoder_encode`, not to us. See docs/CLIENT.md.
//
//  The keycode table is the inverse of Ghostty's own key → keycode map in
//  `macos/Sources/Ghostty/Ghostty.Input.swift`, so the two can be diffed
//  against each other.

import AppKit
import Carbon.HIToolbox
import GhosttyVt

/// One key event, in the terms libghostty-vt's encoder takes.
///
/// A struct rather than a `GhosttyKeyEvent` so translation can be tested
/// without a libghostty handle, and so the handle can be reused per surface
/// instead of allocated per keystroke.
struct KeyEventSpec: Equatable {
    var action: GhosttyKeyAction
    var key: GhosttyKey
    var mods: GhosttyMods
    /// Modifiers that went into producing `text`. macOS does not report
    /// this, so it is the heuristic Ghostty has used for years: control and
    /// command never contribute, assume everything else did.
    var consumedMods: GhosttyMods
    /// The text the layout produced, or nil when the key has none the
    /// encoder should see. Never C0, DEL or a function-key PUA value — the
    /// encoder derives those from `key` itself.
    var text: String?
    /// The codepoint this key produces with no modifiers at all, or 0.
    var unshiftedCodepoint: UInt32
}

enum KeyTranslation {
    // MARK: - Modifiers

    /// AppKit device-dependent modifier masks. These live in IOKit's
    /// `IOLLEvent.h`, which is a kernel header; the values are stable and
    /// public, and repeating them is cheaper than importing IOKit here.
    private enum DeviceMask {
        static let leftControl: UInt = 0x0000_0001
        static let leftShift: UInt = 0x0000_0002
        static let rightShift: UInt = 0x0000_0004
        static let leftCommand: UInt = 0x0000_0008
        static let rightCommand: UInt = 0x0000_0010
        static let leftOption: UInt = 0x0000_0020
        static let rightOption: UInt = 0x0000_0040
        static let rightControl: UInt = 0x0000_2000
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var mods: GhosttyMods = 0
        if flags.contains(.shift) { mods |= UInt16(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { mods |= UInt16(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option) { mods |= UInt16(GHOSTTY_MODS_ALT) }
        if flags.contains(.command) { mods |= UInt16(GHOSTTY_MODS_SUPER) }
        if flags.contains(.capsLock) { mods |= UInt16(GHOSTTY_MODS_CAPS_LOCK) }
        // No num lock: macOS has no such key, and `.numericPad` means "this
        // event came from the keypad or an arrow key", which is a different
        // question entirely.

        // Sidedness. A side bit only means anything when its modifier bit is
        // set, and when both sides are held we can only report one — which
        // is what the header says to expect.
        let raw = flags.rawValue
        if raw & DeviceMask.rightShift != 0 { mods |= UInt16(GHOSTTY_MODS_SHIFT_SIDE) }
        if raw & DeviceMask.rightControl != 0 { mods |= UInt16(GHOSTTY_MODS_CTRL_SIDE) }
        if raw & DeviceMask.rightOption != 0 { mods |= UInt16(GHOSTTY_MODS_ALT_SIDE) }
        if raw & DeviceMask.rightCommand != 0 { mods |= UInt16(GHOSTTY_MODS_SUPER_SIDE) }
        return mods
    }

    /// The modifier bits that never take part in producing text.
    private static let translationExcluded: GhosttyMods =
        UInt16(GHOSTTY_MODS_CTRL) | UInt16(GHOSTTY_MODS_SUPER)

    // MARK: - Events

    /// Translate a `keyDown`/`keyUp` event.
    ///
    /// Returns nil for a keycode we have no physical key for, which the
    /// encoder could not do anything with anyway.
    static func spec(for event: NSEvent) -> KeyEventSpec? {
        guard let key = key(forKeycode: Int(event.keyCode)) else { return nil }

        let action: GhosttyKeyAction
        switch event.type {
        case .keyUp: action = GHOSTTY_KEY_ACTION_RELEASE
        case .keyDown:
            action = event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS
        default: return nil
        }

        let mods = mods(event.modifierFlags)
        return KeyEventSpec(
            action: action,
            key: key,
            mods: mods,
            consumedMods: mods & ~translationExcluded,
            text: action == GHOSTTY_KEY_ACTION_RELEASE ? nil : text(for: event),
            unshiftedCodepoint: unshiftedCodepoint(for: event))
    }

    /// Translate a `flagsChanged` event into a press or release of one
    /// modifier key.
    ///
    /// In legacy mode the encoder produces nothing for these. Under the Kitty
    /// protocol with event reporting on, they are the difference between an
    /// editor seeing that shift went down and it not.
    static func modifierSpec(for event: NSEvent) -> KeyEventSpec? {
        let (key, mask): (GhosttyKey, UInt?)
        switch Int(event.keyCode) {
        case kVK_Shift: (key, mask) = (GHOSTTY_KEY_SHIFT_LEFT, DeviceMask.leftShift)
        case kVK_RightShift: (key, mask) = (GHOSTTY_KEY_SHIFT_RIGHT, DeviceMask.rightShift)
        case kVK_Control: (key, mask) = (GHOSTTY_KEY_CONTROL_LEFT, DeviceMask.leftControl)
        case kVK_RightControl: (key, mask) = (GHOSTTY_KEY_CONTROL_RIGHT, DeviceMask.rightControl)
        case kVK_Option: (key, mask) = (GHOSTTY_KEY_ALT_LEFT, DeviceMask.leftOption)
        case kVK_RightOption: (key, mask) = (GHOSTTY_KEY_ALT_RIGHT, DeviceMask.rightOption)
        case kVK_Command: (key, mask) = (GHOSTTY_KEY_META_LEFT, DeviceMask.leftCommand)
        case kVK_RightCommand: (key, mask) = (GHOSTTY_KEY_META_RIGHT, DeviceMask.rightCommand)
        case kVK_CapsLock: (key, mask) = (GHOSTTY_KEY_CAPS_LOCK, nil)
        default: return nil
        }

        // Down or up is not in the event; it is whether the bit for *this*
        // side is still set afterwards. Caps lock has no side bit, so it
        // falls back to the ordinary flag.
        let down: Bool
        if let mask {
            down = event.modifierFlags.rawValue & mask != 0
        } else {
            down = event.modifierFlags.contains(.capsLock)
        }

        let mods = mods(event.modifierFlags)
        return KeyEventSpec(
            action: down ? GHOSTTY_KEY_ACTION_PRESS : GHOSTTY_KEY_ACTION_RELEASE,
            key: key,
            mods: mods,
            consumedMods: mods & ~translationExcluded,
            text: nil,
            unshiftedCodepoint: 0)
    }

    // MARK: - Text

    /// The text to hand the encoder, or nil.
    ///
    /// `ghostty_key_event_set_utf8` explicitly refuses C0, DEL and the
    /// function-key PUA block: the encoder derives those from the logical key
    /// instead, and passing them would encode the key twice. A control
    /// character here means control was held, so we ask the layout what the
    /// key produces without it.
    static func text(for event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }

        if characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first {
            if isFunctionKeyPUA(scalar) { return nil }
            if isControl(scalar) {
                let retranslated = event.characters(
                    byApplyingModifiers: event.modifierFlags.subtracting(.control))
                guard let retranslated, !retranslated.isEmpty else { return nil }
                if let scalar = retranslated.unicodeScalars.first,
                    retranslated.unicodeScalars.count == 1,
                    isControl(scalar) || isFunctionKeyPUA(scalar)
                {
                    return nil
                }
                return retranslated
            }
        }

        return characters
    }

    /// What this key produces with no modifiers at all.
    ///
    /// The Kitty protocol reports it as the base key, so `ctrl+shift+7` on a
    /// German layout still says the key was `7`. Zero when the key produces
    /// no printable codepoint, which tells the encoder to use `key` instead.
    static func unshiftedCodepoint(for event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp else { return 0 }
        // Not `charactersIgnoringModifiers`: that one changes behaviour when
        // control is held, which is exactly the case we are trying to see
        // through.
        guard let characters = event.characters(byApplyingModifiers: []),
            let scalar = characters.unicodeScalars.first
        else { return 0 }
        guard !isControl(scalar), !isFunctionKeyPUA(scalar) else { return 0 }
        return scalar.value
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7f
    }

    /// macOS reports arrows, function keys and the like as private-use
    /// codepoints in `characters`. They are not text.
    private static func isFunctionKeyPUA(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0xf700 && scalar.value <= 0xf8ff
    }

    // MARK: - The keycode table

    /// macOS virtual keycode → physical key.
    ///
    /// `kVK_ContextMenu` is not in Carbon's `Events.h`, so 0x6e is spelled
    /// out. Everything else uses the named constant.
    static func key(forKeycode keycode: Int) -> GhosttyKey? {
        switch keycode {
        // Writing system keys
        case kVK_ANSI_A: return GHOSTTY_KEY_A
        case kVK_ANSI_B: return GHOSTTY_KEY_B
        case kVK_ANSI_C: return GHOSTTY_KEY_C
        case kVK_ANSI_D: return GHOSTTY_KEY_D
        case kVK_ANSI_E: return GHOSTTY_KEY_E
        case kVK_ANSI_F: return GHOSTTY_KEY_F
        case kVK_ANSI_G: return GHOSTTY_KEY_G
        case kVK_ANSI_H: return GHOSTTY_KEY_H
        case kVK_ANSI_I: return GHOSTTY_KEY_I
        case kVK_ANSI_J: return GHOSTTY_KEY_J
        case kVK_ANSI_K: return GHOSTTY_KEY_K
        case kVK_ANSI_L: return GHOSTTY_KEY_L
        case kVK_ANSI_M: return GHOSTTY_KEY_M
        case kVK_ANSI_N: return GHOSTTY_KEY_N
        case kVK_ANSI_O: return GHOSTTY_KEY_O
        case kVK_ANSI_P: return GHOSTTY_KEY_P
        case kVK_ANSI_Q: return GHOSTTY_KEY_Q
        case kVK_ANSI_R: return GHOSTTY_KEY_R
        case kVK_ANSI_S: return GHOSTTY_KEY_S
        case kVK_ANSI_T: return GHOSTTY_KEY_T
        case kVK_ANSI_U: return GHOSTTY_KEY_U
        case kVK_ANSI_V: return GHOSTTY_KEY_V
        case kVK_ANSI_W: return GHOSTTY_KEY_W
        case kVK_ANSI_X: return GHOSTTY_KEY_X
        case kVK_ANSI_Y: return GHOSTTY_KEY_Y
        case kVK_ANSI_Z: return GHOSTTY_KEY_Z
        case kVK_ANSI_0: return GHOSTTY_KEY_DIGIT_0
        case kVK_ANSI_1: return GHOSTTY_KEY_DIGIT_1
        case kVK_ANSI_2: return GHOSTTY_KEY_DIGIT_2
        case kVK_ANSI_3: return GHOSTTY_KEY_DIGIT_3
        case kVK_ANSI_4: return GHOSTTY_KEY_DIGIT_4
        case kVK_ANSI_5: return GHOSTTY_KEY_DIGIT_5
        case kVK_ANSI_6: return GHOSTTY_KEY_DIGIT_6
        case kVK_ANSI_7: return GHOSTTY_KEY_DIGIT_7
        case kVK_ANSI_8: return GHOSTTY_KEY_DIGIT_8
        case kVK_ANSI_9: return GHOSTTY_KEY_DIGIT_9
        case kVK_ANSI_Grave: return GHOSTTY_KEY_BACKQUOTE
        case kVK_ANSI_Backslash: return GHOSTTY_KEY_BACKSLASH
        case kVK_ANSI_LeftBracket: return GHOSTTY_KEY_BRACKET_LEFT
        case kVK_ANSI_RightBracket: return GHOSTTY_KEY_BRACKET_RIGHT
        case kVK_ANSI_Comma: return GHOSTTY_KEY_COMMA
        case kVK_ANSI_Equal: return GHOSTTY_KEY_EQUAL
        case kVK_ANSI_Minus: return GHOSTTY_KEY_MINUS
        case kVK_ANSI_Period: return GHOSTTY_KEY_PERIOD
        case kVK_ANSI_Quote: return GHOSTTY_KEY_QUOTE
        case kVK_ANSI_Semicolon: return GHOSTTY_KEY_SEMICOLON
        case kVK_ANSI_Slash: return GHOSTTY_KEY_SLASH
        case kVK_ISO_Section: return GHOSTTY_KEY_INTL_BACKSLASH
        case kVK_JIS_Underscore: return GHOSTTY_KEY_INTL_RO
        case kVK_JIS_Yen: return GHOSTTY_KEY_INTL_YEN

        // Functional keys
        case kVK_Option: return GHOSTTY_KEY_ALT_LEFT
        case kVK_RightOption: return GHOSTTY_KEY_ALT_RIGHT
        case kVK_Delete: return GHOSTTY_KEY_BACKSPACE
        case kVK_CapsLock: return GHOSTTY_KEY_CAPS_LOCK
        case 0x6e: return GHOSTTY_KEY_CONTEXT_MENU
        case kVK_Control: return GHOSTTY_KEY_CONTROL_LEFT
        case kVK_RightControl: return GHOSTTY_KEY_CONTROL_RIGHT
        case kVK_Return: return GHOSTTY_KEY_ENTER
        case kVK_Command: return GHOSTTY_KEY_META_LEFT
        case kVK_RightCommand: return GHOSTTY_KEY_META_RIGHT
        case kVK_Shift: return GHOSTTY_KEY_SHIFT_LEFT
        case kVK_RightShift: return GHOSTTY_KEY_SHIFT_RIGHT
        case kVK_Space: return GHOSTTY_KEY_SPACE
        case kVK_Tab: return GHOSTTY_KEY_TAB

        // Control pad. macOS puts Help where a PC keyboard has Insert, and
        // Ghostty maps it that way too.
        case kVK_ForwardDelete: return GHOSTTY_KEY_DELETE
        case kVK_End: return GHOSTTY_KEY_END
        case kVK_Home: return GHOSTTY_KEY_HOME
        case kVK_Help: return GHOSTTY_KEY_INSERT
        case kVK_PageDown: return GHOSTTY_KEY_PAGE_DOWN
        case kVK_PageUp: return GHOSTTY_KEY_PAGE_UP

        // Arrow pad
        case kVK_DownArrow: return GHOSTTY_KEY_ARROW_DOWN
        case kVK_LeftArrow: return GHOSTTY_KEY_ARROW_LEFT
        case kVK_RightArrow: return GHOSTTY_KEY_ARROW_RIGHT
        case kVK_UpArrow: return GHOSTTY_KEY_ARROW_UP

        // Numpad. "Clear" sits where a PC keyboard has Num Lock.
        case kVK_ANSI_KeypadClear: return GHOSTTY_KEY_NUM_LOCK
        case kVK_ANSI_Keypad0: return GHOSTTY_KEY_NUMPAD_0
        case kVK_ANSI_Keypad1: return GHOSTTY_KEY_NUMPAD_1
        case kVK_ANSI_Keypad2: return GHOSTTY_KEY_NUMPAD_2
        case kVK_ANSI_Keypad3: return GHOSTTY_KEY_NUMPAD_3
        case kVK_ANSI_Keypad4: return GHOSTTY_KEY_NUMPAD_4
        case kVK_ANSI_Keypad5: return GHOSTTY_KEY_NUMPAD_5
        case kVK_ANSI_Keypad6: return GHOSTTY_KEY_NUMPAD_6
        case kVK_ANSI_Keypad7: return GHOSTTY_KEY_NUMPAD_7
        case kVK_ANSI_Keypad8: return GHOSTTY_KEY_NUMPAD_8
        case kVK_ANSI_Keypad9: return GHOSTTY_KEY_NUMPAD_9
        case kVK_ANSI_KeypadPlus: return GHOSTTY_KEY_NUMPAD_ADD
        case kVK_JIS_KeypadComma: return GHOSTTY_KEY_NUMPAD_COMMA
        case kVK_ANSI_KeypadDecimal: return GHOSTTY_KEY_NUMPAD_DECIMAL
        case kVK_ANSI_KeypadDivide: return GHOSTTY_KEY_NUMPAD_DIVIDE
        case kVK_ANSI_KeypadEnter: return GHOSTTY_KEY_NUMPAD_ENTER
        case kVK_ANSI_KeypadEquals: return GHOSTTY_KEY_NUMPAD_EQUAL
        case kVK_ANSI_KeypadMultiply: return GHOSTTY_KEY_NUMPAD_MULTIPLY
        case kVK_ANSI_KeypadMinus: return GHOSTTY_KEY_NUMPAD_SUBTRACT

        // Function section
        case kVK_Escape: return GHOSTTY_KEY_ESCAPE
        case kVK_F1: return GHOSTTY_KEY_F1
        case kVK_F2: return GHOSTTY_KEY_F2
        case kVK_F3: return GHOSTTY_KEY_F3
        case kVK_F4: return GHOSTTY_KEY_F4
        case kVK_F5: return GHOSTTY_KEY_F5
        case kVK_F6: return GHOSTTY_KEY_F6
        case kVK_F7: return GHOSTTY_KEY_F7
        case kVK_F8: return GHOSTTY_KEY_F8
        case kVK_F9: return GHOSTTY_KEY_F9
        case kVK_F10: return GHOSTTY_KEY_F10
        case kVK_F11: return GHOSTTY_KEY_F11
        case kVK_F12: return GHOSTTY_KEY_F12
        case kVK_F13: return GHOSTTY_KEY_F13
        case kVK_F14: return GHOSTTY_KEY_F14
        case kVK_F15: return GHOSTTY_KEY_F15
        case kVK_F16: return GHOSTTY_KEY_F16
        case kVK_F17: return GHOSTTY_KEY_F17
        case kVK_F18: return GHOSTTY_KEY_F18
        case kVK_F19: return GHOSTTY_KEY_F19
        case kVK_F20: return GHOSTTY_KEY_F20

        // Media
        case kVK_VolumeDown: return GHOSTTY_KEY_AUDIO_VOLUME_DOWN
        case kVK_Mute: return GHOSTTY_KEY_AUDIO_VOLUME_MUTE
        case kVK_VolumeUp: return GHOSTTY_KEY_AUDIO_VOLUME_UP

        default: return nil
        }
    }
}
