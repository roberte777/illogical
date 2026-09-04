//  WindowChrome.swift
//  Makes the window's content span the full height, traffic lights included.
//
//  SwiftUI's `.hiddenTitleBar` hides the title but still reserves a title bar
//  strip, so app content starts *below* the traffic lights. Superlogical puts
//  the session button and the tab strip on the same row as the lights, so we
//  need the content to extend under the title bar and to reserve horizontal
//  room for the lights instead.
//
//  Two pieces:
//    * `.fullSizeContentView` so the content view starts at the window's top.
//    * A zero-content titlebar accessory that pads the title bar out to the
//      toolbar height, which makes AppKit centre the traffic lights in it.
//      Measured against Superlogical: the lights are centred in a 39pt bar.

import AppKit
import SwiftUI

/// A titlebar accessory that exists only to set the title bar's height. It must
/// not eat clicks aimed at the tab strip underneath it.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct WindowChrome: NSViewRepresentable {
    let toolbarHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }

        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        // AppKit's default title bar is 28pt. Pad it to the toolbar height so
        // the traffic lights land on the same centre line as the tabs.
        let standardTitleBarHeight: CGFloat = 28
        let extra = max(0, toolbarHeight - standardTitleBarHeight)
        let alreadyAdded = window.titlebarAccessoryViewControllers.contains {
            $0.view is PassthroughView
        }
        if extra > 0, !alreadyAdded {
            let accessory = NSTitlebarAccessoryViewController()
            let spacer = PassthroughView(frame: NSRect(x: 0, y: 0, width: 1, height: extra))
            accessory.view = spacer
            accessory.layoutAttribute = .top
            window.addTitlebarAccessoryViewController(accessory)
        }
    }
}
