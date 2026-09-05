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
//  the space no control occupies drags the window, for free.

import AppKit
import SwiftUI

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
