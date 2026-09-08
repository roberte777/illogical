//  TabCycleKey.swift
//  ⌃⇥ and ⌃⇧⇥ — the tab chords no menu item can hold.
//
//  Every other tab chord is a menu item, for the reason IllogicalApp states: a
//  chord the key-equivalent pass claims never reaches `keyDown`, so the menu
//  bar is also the list of things that can never be typed into a terminal.
//  These two cannot be. AppKit gives a menu item exactly one key equivalent,
//  and "Show Next Tab" spends its on ⇧⌘] — the chord the Window menu has to go
//  on displaying, because the menu is where a user finds out what the app can
//  do. Safari and Terminal.app carry both by hanging a second, hidden item off
//  the same action; SwiftUI's `commands` has no spelling for one.
//
//  So this is `onEscape`'s local `NSEvent` monitor again, and it inherits the
//  same guarantee: a local monitor runs inside `NSApplication.sendEvent(_:)`,
//  before the event is routed anywhere, and returning `nil` drops it. ⌃⇥ never
//  reaches the surface — which is the point. Under the Kitty protocol it is a
//  real key a program can bind, so a chord that both switched tabs *and* went
//  down the wire would be one keystroke doing two jobs.
//
//  It is claimed unconditionally, even with a single tab. The alternative —
//  falling through when there is nowhere to go — would make ⌃⇥ mean "switch
//  tabs" or "send ⌃⇥ to the program" depending on how many tabs happen to be
//  open, which is not something anyone can hold in their head. The menu items
//  behave the same way: a *disabled* item still consumes its key equivalent.

import AppKit
import SwiftUI

extension View {
    /// Run `action` on ⌃⇥ / ⌃⇧⇥ while this view is on screen, whichever view
    /// has focus.
    func onTabCycle(perform action: @escaping (TabCycle.Direction) -> Void) -> some View {
        modifier(TabCycleKey(action: action))
    }
}

/// Which way ⌃⇥ goes, as a pure function of the event.
enum TabCycle {
    enum Direction {
        case next
        case previous
    }

    static func direction(for event: NSEvent) -> Direction? {
        direction(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    /// ⌃ **and nothing else**, plus ⇧ for the way back.
    ///
    /// Exact rather than `contains(.control)`, for the reason the viewport
    /// chords are: bare ⇥ is completion in every shell, ⌥⌃⇥ and ⌘⇥ belong
    /// elsewhere, and a loose test would eat all of them. Measured against
    /// `deviceIndependentFlagsMask` so the caps-lock bit and the left/right
    /// device bits AppKit also sets do not count as modifiers.
    static func direction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Direction? {
        guard keyCode == tabKeyCode else { return nil }
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        if mods == .control { return .next }
        if mods == [.control, .shift] { return .previous }
        return nil
    }

    /// `kVK_Tab`. Spelled out rather than importing Carbon for one constant,
    /// as `EscapeKey` does with `kVK_Escape`.
    static let tabKeyCode: UInt16 = 48
}

/// The monitor behind `onTabCycle`, kept out of the extension so its lifetime
/// is a `@State` and dies with the view rather than with a window.
private struct TabCycleKey: ViewModifier {
    let action: (TabCycle.Direction) -> Void

    /// A class, so the handler that outlives each `body` pass writes to one
    /// `owesKeyUp` rather than to a copy of it. It also holds what
    /// `NSEvent.removeMonitor` wants back — exactly what
    /// `addLocalMonitorForEvents` returned, and that is an `Any`.
    @State private var state = MonitorState()

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Guarded: SwiftUI may run `onAppear` again without an
                // intervening `onDisappear`, and two monitors would both fire.
                guard state.monitor == nil else { return }
                state.monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.keyDown, .keyUp]
                ) { event in
                    MainActor.assumeIsolated { claims(event) } ? nil : event
                }
            }
            .onDisappear {
                if let monitor = state.monitor { NSEvent.removeMonitor(monitor) }
                state.monitor = nil
                state.owesKeyUp = false
            }
    }

    /// Whether this event belongs to the chord — and, on the way down, act on
    /// it. `true` means drop it.
    @MainActor
    private func claims(_ event: NSEvent) -> Bool {
        if event.type == .keyUp {
            // Matched on the keycode this took on the way *down*, never on the
            // release event's modifiers — the rule the surface's viewport
            // chords follow, and for the same bug. Letting go of ⌃ before ⇥ is
            // the ordinary way anyone releases this chord, and it produces a
            // key-up with no ⌃ in it; under the Kitty protocol that release
            // would go down the wire for a press the program never saw.
            //
            // Nothing else in the app needs this, because everything else is
            // ⌘-bearing: AppKit delivers no `keyUp` at all while ⌘ is held, so
            // ⇧⌘] has no release to swallow.
            guard event.keyCode == TabCycle.tabKeyCode, state.owesKeyUp else { return false }
            state.owesKeyUp = false
            return true
        }
        guard let direction = TabCycle.direction(for: event) else { return false }
        // A held chord repeats: many downs, one up. So this is a flag rather
        // than a count.
        state.owesKeyUp = true
        action(direction)
        return true
    }

    private final class MonitorState {
        var monitor: Any?
        /// A ⌃⇥ `keyDown` this dropped, owed a dropped `keyUp`.
        var owesKeyUp = false
    }
}
