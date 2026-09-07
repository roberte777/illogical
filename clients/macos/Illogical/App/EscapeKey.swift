//  EscapeKey.swift
//  Escape, wherever the keyboard happens to be.
//
//  SwiftUI's `.onExitCommand` is a *focus* modifier: AppKit turns Escape into
//  `cancelOperation:`, sends it down the responder chain, and SwiftUI offers it
//  to the focused view and its ancestors. Nothing focused inside the view, no
//  handler.
//
//  That is why W10 shipped broken. The session menu asks for focus as it appears
//  -- `.onAppear { fieldFocused = true }` on the filter field -- and the request
//  does not land: with the menu open, the app's `AXFocusedUIElement` is still
//  the terminal surface underneath, and the field's `AXFocused` is false. So the
//  menu was never in the focus chain, `.onExitCommand` never fired, and Escape
//  went to the terminal. (Clicking the field first *does* focus it, and Escape
//  then closes the menu, which is how the mechanism was pinned down.)
//
//  A local `NSEvent` monitor does not care. It runs inside
//  `NSApplication.sendEvent(_:)`, before the event is routed anywhere, so it
//  sees Escape whatever holds first responder -- or whether anything does. It is
//  installed only while the view using it is on screen, so nothing steals
//  Escape from the terminal the rest of the time, and it returns `nil` so the
//  keystroke that closed an overlay is not also delivered underneath it.

import AppKit
import SwiftUI

extension View {
    /// Run `action` on Escape while this view is on screen, whichever view has
    /// focus. Prefer `.onExitCommand` when focus is genuinely inside the view;
    /// this is for overlays that must close from anywhere.
    func onEscape(perform action: @escaping () -> Void) -> some View {
        modifier(EscapeKey(action: action))
    }
}

/// The monitor behind `onEscape`, kept out of the extension so its lifetime is
/// a `@State` and dies with the view rather than with a window.
private struct EscapeKey: ViewModifier {
    let action: () -> Void

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
                    guard event.keyCode == EscapeKey.escapeKeyCode else { return event }
                    MainActor.assumeIsolated { action() }
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// `kVK_Escape`. Spelled out rather than imported from Carbon for one
    /// constant.
    private static let escapeKeyCode: UInt16 = 53
}
