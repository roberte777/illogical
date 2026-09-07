//  WindowChrome.swift
//  Puts the toolbar where AppKit expects it: inside the title bar.
//
//  Superlogical has the session button and tab strip on the same row as the
//  traffic lights. The obvious way to get that in SwiftUI -- hide the title bar,
//  turn on `fullSizeContentView`, and draw a toolbar row at the top of the
//  content view -- looks right and is subtly broken: the title bar's own view
//  sits above the content view, so mouse events in that strip belong to it, not
//  to the controls drawn underneath. Hover still works, because tracking areas
//  are independent, which makes it read as a SwiftUI hit-testing bug.
//
//  `isMovableByWindowBackground` makes it worse rather than better: it turns a
//  mouse-down anywhere the window considers background into a window drag.
//
//  The fix is to stop fighting AppKit. The toolbar becomes an
//  `NSTitlebarAccessoryViewController`, so it *is* the title bar: it receives
//  clicks, the traffic lights are centred against its height automatically, and
//  the space no control occupies drags the window -- nearly for free.
//
//  Nearly, and this is the caveat: "the space no control occupies" is not
//  decided by where the controls are drawn. AppKit works it out from
//  `mouseDownCanMoveWindow`, which every view in the title bar answers for
//  itself, and an `NSHostingView` full of SwiftUI says *yes* for all of it --
//  nothing SwiftUI draws is an opaque `NSView`, which is the only thing that
//  makes AppKit's default answer `false`. So the whole accessory was window
//  chrome, and a mouse-down on a tab went to the window's own drag loop before
//  any SwiftUI gesture could see it: drag-to-reorder (#38) moved the window and
//  reordered nothing, and a drag begun on `+` moved the window and then made a
//  terminal on mouse-up. `claimsMouseDown()` below is how a control opts out.

import AppKit
import SwiftUI

/// Marks the space this view occupies as *not* window chrome, so a mouse-down
/// on it reaches the view instead of starting a window drag.
///
/// A one-line `NSView` because `mouseDownCanMoveWindow` is an `NSView` question
/// and SwiftUI has no answer for it. It goes in as a `.background`, which is
/// enough: AppKit subtracts the frame of every view that says `false` from the
/// window's draggable region, and it never has to be the view the click is
/// *delivered* to -- so the SwiftUI buttons drawn over it keep working, which
/// is exactly what the live check found.
struct ClaimsMouseDown: NSViewRepresentable {
    final class BackingView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    func makeNSView(context: Context) -> BackingView { BackingView(frame: .zero) }
    func updateNSView(_ nsView: BackingView, context: Context) {}
}

extension View {
    /// Take mouse-downs on this view rather than letting the title bar drag the
    /// window with them. Only needed inside the toolbar accessory; everywhere
    /// else the window is not movable by its background anyway.
    func claimsMouseDown() -> some View {
        background(ClaimsMouseDown())
    }
}

@MainActor
struct WindowChrome<Toolbar: View>: NSViewRepresentable {
    let toolbarHeight: CGFloat
    @ViewBuilder let toolbar: () -> Toolbar

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window, context: context) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window, context: context) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var accessory: NSTitlebarAccessoryViewController?
    }

    private func configure(_ window: NSWindow?, context: Context) {
        guard let window else { return }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Never true: it would turn clicks on the toolbar into window drags.
        // The accessory view gives us dragging on its empty space anyway.
        //
        // It is also not the knob that decides whether a *title bar* drag moves
        // the window -- that one is per-view, `mouseDownCanMoveWindow`, and is
        // why `claimsMouseDown()` exists. With this already `false` the terminal
        // body correctly ignored a drag while the tab strip above it did not.
        window.isMovableByWindowBackground = false

        if let existing = context.coordinator.accessory {
            // Keep the hosted SwiftUI view current across state changes.
            (existing.view as? NSHostingView<Toolbar>)?.rootView = toolbar()
            return
        }

        let hosting = NSHostingView(rootView: toolbar())
        hosting.frame = NSRect(x: 0, y: 0, width: window.frame.width, height: toolbarHeight)
        hosting.autoresizingMask = [.width]

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = hosting
        accessory.layoutAttribute = .top
        accessory.fullScreenMinHeight = toolbarHeight
        window.addTitlebarAccessoryViewController(accessory)
        context.coordinator.accessory = accessory
    }
}
