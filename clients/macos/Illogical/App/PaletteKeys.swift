//  PaletteKeys.swift
//  ↑ ↓ ⌫ while the command palette is open.
//
//  The palette's field holds the keyboard, so these three would otherwise go
//  where every other character goes: the arrows would move the caret and ⌫
//  would delete nothing at the start of an empty field. They are the palette's
//  while it is on screen, so this is `EscapeKey`'s local `NSEvent` monitor
//  again, with the same guarantee — a local monitor runs inside
//  `NSApplication.sendEvent(_:)`, before the event is routed anywhere, so it
//  sees the key whatever holds first responder, and returning `nil` means the
//  keystroke that moved the selection is not also typed into the field.
//
//  Return is deliberately NOT here. It reaches the field as `.onSubmit`, which
//  is how the dropdown's filter field already commits, and a monitor for it
//  would be a second owner of the same keystroke.
//
//  Nor is there a monitor for any command's chord. Every one of them is a menu
//  item, and a chord the key-equivalent pass claims never reaches `keyDown` —
//  so ⇧⌘N works with the palette open without this file doing anything, and ⌘K
//  opens the dropdown, which closes the palette through the store's own
//  exclusion.
//
//  Four of those chords are arrows, though. ⌥⌘←→↑↓ move focus between panes,
//  and a chord arrives with the same keycode as the bare key under it — so
//  getting out of their way is the one thing this file *does* have to do about
//  chords. The claim below is therefore on the whole keystroke rather than on
//  the keycode: only an unmodified key is the palette's. Switching on the
//  keycode alone swallowed ⌥⌘↑ and ⌥⌘↓ to move the highlight while ⌥⌘← and
//  ⌥⌘→ went past and moved pane focus, which is one chord family meaning two
//  different things depending on which way it points. Passed through, a
//  modified arrow reaches the key-equivalent pass, runs Focus Pane, and takes
//  the panel down on its way out through `runCommand`'s dismissal — which is
//  what ⌥⌘← was doing all along.
//
//  The decisions are pure values, exactly as `TabCycle.Matcher` is, and for the
//  same reason: neither a `ViewModifier`'s monitor closure nor a hover callback
//  is something a unit test can build, and every rule below is worth pinning —
//  which keys are claimed, where an arrow lands among rows that are not all
//  selectable, where the highlight goes when the row under it dims, and when a
//  hover is the mouse moving rather than the list moving under it.
//
//  The last two are not keys and are here anyway, because they are the same
//  question: which row does Return act on. Splitting them across files would
//  put three of the four answers in one place and the fourth somewhere a
//  reader has no reason to look.

import AppKit
import SwiftUI

extension View {
    /// Offer every `keyDown` to `handle` while this view is on screen. An
    /// event `handle` answers `true` for is claimed and delivered nowhere else.
    ///
    /// The whole decision is the caller's, rather than this modifier taking the
    /// palette's stage and query as parameters, and that is not a style
    /// preference: the monitor is installed once in `onAppear`, so any value
    /// passed in here would be frozen at the first body pass, and both of those
    /// inputs change on every keystroke. A closure the caller writes reads them
    /// live. `PaletteKeys.claim` below is the rule it should read them with.
    func onPaletteKey(_ handle: @escaping (UInt16, NSEvent.ModifierFlags) -> Bool) -> some View {
        modifier(PaletteKeyMonitor(handle: handle))
    }
}

/// What the palette does with a key, and where an arrow lands.
enum PaletteKeys {
    /// `kVK_UpArrow`, `kVK_DownArrow` and `kVK_Delete`. Spelled out rather than
    /// importing Carbon for three constants, as `EscapeKey` does with
    /// `kVK_Escape`.
    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
    static let delete: UInt16 = 51

    enum Claim: Equatable {
        /// Not ours. Hand it on — including every printable character, which
        /// is the field's.
        case pass
        case up
        case down
        /// ⌫ with nothing left to delete: take the chip back and return to the
        /// list of commands.
        case popArgument
    }

    /// The four modifiers a person actually holds down.
    ///
    /// Everything else in the mask is a fact about the key rather than about
    /// the keystroke, and this is the whole trap of the guard below: **an arrow
    /// key arrives carrying `.function` and `.numericPad`** whether or not
    /// anybody touched a modifier. So the test has to be an intersection with
    /// these four and never an emptiness test — not on the raw mask and not on
    /// `deviceIndependentFlagsMask` either, both of which are non-empty for
    /// every arrow this file exists to claim. Get it wrong and every arrow
    /// passes through and the palette has no navigation at all.
    static let heldModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// The arrows are claimed in both stages, even in a stage two whose list is
    /// a sentence. `TabCycleKey` argues the general form: a key that means
    /// "move the selection" or "move the caret" depending on which stage
    /// happens to be up is not something anyone can hold in their head, and a
    /// one-line field has nothing for an arrow to usefully do anyway.
    ///
    /// But only *bare* — a modified arrow is a chord, and a chord is a
    /// command's name. ⌥⌘↑ is Focus Pane Above and belongs to the menu bar;
    /// ⇧↑ is the field selecting text; ⌥⌫ and ⌘⌫ are the field's word and line
    /// deletes, and they stay the field's even with nothing to delete, because
    /// somebody who has learnt ⌥⌫ has not learnt "unless the field is empty, in
    /// which case it takes the chip instead".
    ///
    /// Bare ⌫ is the opposite of the arrows, and narrowly conditional on
    /// purpose. It is the field's key — correcting a typo is the commonest
    /// thing anyone does in a search field — so it is only the palette's in the
    /// one position where the field has nothing to correct: stage two, empty.
    /// `queryIsEmpty` is the literal emptiness of the field and not a trimmed
    /// one, because a space somebody typed is a character they can expect ⌫ to
    /// take back.
    static func claim(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, stageIsArgument: Bool,
        queryIsEmpty: Bool
    ) -> Claim {
        guard modifiers.intersection(heldModifiers).isEmpty else { return .pass }
        switch keyCode {
        case upArrow: return .up
        case downArrow: return .down
        case delete: return stageIsArgument && queryIsEmpty ? .popArgument : .pass
        default: return .pass
        }
    }

    /// Where an arrow lands: the next row in that direction that can actually
    /// be run, or where it started when there is none.
    ///
    /// Skipping is what makes dimmed rows honest. They are drawn because
    /// hiding them would make the palette lie about what the app can do, and
    /// they are unreachable because a highlighted row whose Return does nothing
    /// is the silent no-op this codebase keeps killing.
    ///
    /// Clamping rather than wrapping, unlike the tab chords. ⇧⌘] cycles a
    /// handful of tabs; this is a list of twenty-two that scrolls, and an arrow
    /// that teleports from the last row to the first loses the person's place.
    ///
    /// `from: -1, by: 1` is also how the first selectable row is found after a
    /// filter changes — a position before the list, stepped forward — so there
    /// is one rule for both rather than a second search that could disagree
    /// with this one about which rows count.
    static func step(from index: Int, by delta: Int, enabled: [Bool]) -> Int {
        guard delta != 0 else { return index }
        var next = index + delta
        while enabled.indices.contains(next) {
            if enabled[next] { return next }
            next += delta
        }
        return index
    }

    /// Where the highlight goes when the row *under* it dims.
    ///
    /// Nothing moved and nothing was typed: the app changed. Delete Session…
    /// greys out when its machine drops, and Close Tab greys out when the last
    /// tab goes — which can happen with the panel up, because the titlebar's
    /// own ✕ stays live underneath it. The highlight stayed where it was and
    /// Return then did nothing at all, with nothing on screen saying why; that
    /// is the same silent no-op the dimming rule and `step` above exist to
    /// prevent, arriving from the one direction neither of them watched.
    ///
    /// Forward first, because that is the direction an arrow was last going
    /// and it keeps the highlight ahead of where the person was reading. Then
    /// back, for a row that dimmed at the end of the list, where there is
    /// nothing ahead of it. Then nothing at all, which is honest: a list with
    /// nothing runnable in it should not be pointing at a row.
    ///
    /// An index outside the list is the list having shrunk rather than a row
    /// having dimmed — a filter and a predicate changing in the same pass —
    /// and starts again from the top, exactly as `resetSelection` does.
    /// `step` cannot walk in from outside: it stops the moment it is off the
    /// end, so from beyond the last row it never enters the list at all.
    static func restep(from index: Int, enabled: [Bool]) -> Int {
        guard enabled.indices.contains(index) else {
            return step(from: -1, by: 1, enabled: enabled)
        }
        if enabled[index] { return index }
        for delta in [1, -1] {
            // In range, because `step` returns where it started when it finds
            // nothing and where it started is in range.
            let next = step(from: index, by: delta, enabled: enabled)
            if enabled[next] { return next }
        }
        return -1
    }

    /// Whether a hover is the pointer moving onto a row, or a row arriving
    /// under a pointer that has not moved at all.
    ///
    /// Hover callbacks fire whenever the view under the pointer changes, and
    /// it does not have to be the pointer that changed it. The palette moves
    /// rows under a stationary mouse twice, and both were bugs. The panel is
    /// centred and hangs 30pt down — where a pointer very often already rests
    /// — so opening it put a row under the mouse, whose hover overwrote the
    /// first-row highlight `onAppear` had just set: ⇧⌘P then Return ran
    /// whatever the pointer happened to be over. And an arrow past the visible
    /// fold scrolls the list, which puts a *new* row under that same
    /// stationary pointer, whose hover snapped the highlight back and cleared
    /// the pending scroll with it — so with the mouse anywhere over the panel
    /// the last commands in the table could not be reached by arrow at all.
    ///
    /// So a hover only counts once the pointer has been seen somewhere else.
    /// `nil` is "not seen yet", which is the panel's first frame: it records
    /// where the pointer is and changes nothing. This is what `NSMenu` and
    /// Spotlight both do — a menu opened under the mouse highlights its own
    /// first item, and starts following the mouse when the mouse moves.
    ///
    /// Comparing positions rather than timing a runloop turn after each
    /// `scrollTo`, which was the other way to do it: a deadline says "ignore
    /// hovers for a moment and hope", where a position answers the question
    /// actually being asked. The points must be in a space the *panel* does
    /// not move in — window coordinates, not the row's own — or a row sliding
    /// under a still pointer reports a new position and reads as a move.
    static func hoverMoved(from previous: CGPoint?, to point: CGPoint) -> Bool {
        guard let previous else { return false }
        return previous != point
    }
}

/// The monitor behind `onPaletteKey`, kept out of the extension so its lifetime
/// is a `@State` and dies with the view rather than with a window.
private struct PaletteKeyMonitor: ViewModifier {
    let handle: (UInt16, NSEvent.ModifierFlags) -> Bool

    /// `NSEvent.removeMonitor` wants back exactly what `addLocalMonitor…`
    /// returned, and that is an `Any`.
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Guarded: SwiftUI may run `onAppear` again without an
                // intervening `onDisappear`, and two monitors would both fire.
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let claimed = MainActor.assumeIsolated {
                        handle(event.keyCode, event.modifierFlags)
                    }
                    return claimed ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
