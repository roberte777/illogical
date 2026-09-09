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

        // Everything AppKit draws for us rather than us for it: the traffic
        // lights, the buttons on the two placeholder screens, a sheet, a
        // scroller. Our own chrome follows the theme by being derived from it
        // (`Palette`), but none of these are ours to paint, and a light
        // terminal in a window macOS still believes is dark comes with
        // white-on-white system buttons.
        //
        // `window-theme` decides it; `auto` reads the theme's background. See
        // `ConfigWindowTheme`.
        window.appearance = AppConfig.windowAppearance

        // A translucent terminal needs a window that is not opaque, or what
        // shows through the surface is the window's own background rather
        // than the desktop. Left alone at the default when nobody asked for
        // one: a non-opaque window is composited differently whether or not
        // anything in it is actually see-through, and the terminal is the
        // one view in the app that would pay for that.
        //
        // Only the terminal *is* see-through, in any case. Every piece of
        // chrome paints its own opaque background, so the clear window colour
        // is visible nowhere but inside a pane.
        if AppConfig.isTranslucent {
            window.isOpaque = false
            window.backgroundColor = .clear

            // Clear is right for the content, where the terminal is, and
            // wrong for the title bar — and the title bar is not entirely
            // ours to paint. AppKit insets the accessory past the traffic
            // lights (see `Metrics.toolbarLeading`) and leaves a sliver at
            // the trailing end, so the strip behind the lights and that
            // sliver are the window's own background. With a clear window
            // they became the only see-through chrome in the app: the tab
            // strip opaque, the traffic lights sitting on the desktop.
            //
            // So the title bar's own view gets the colour the accessory is
            // already painting, and the two meet without a seam. Asked for by
            // its close button because that is the one handle on the view
            // AppKit will admit to owning.
            if let titlebar = window.standardWindowButton(.closeButton)?.superview {
                titlebar.wantsLayer = true
                titlebar.layer?.backgroundColor = Palette.toolbar.cgColor
            }

            WindowBlur.apply(radius: AppConfig.current.backgroundBlurRadius, to: window)
        }
        // Never true: it would turn clicks on the toolbar into window drags.
        // The accessory view gives us dragging on its empty space anyway.
        //
        // It is also not the knob that decides whether a *title bar* drag moves
        // the window -- that one is per-view, `mouseDownCanMoveWindow`, and is
        // why `claimsMouseDown()` exists. With this already `false` the terminal
        // body correctly ignored a drag while the tab strip above it did not.
        window.isMovableByWindowBackground = false

        // A toolbar is a band the user can revoke, so this is the band being
        // taken back. The toolbar below is attached for its height and nothing
        // else, and hiding it takes `NSTitlebarView` back to a plain window's
        // 32pt with the 40pt accessory clipped inside it — the exact fault
        // that toolbar exists to fix, arriving with no UI left to explain it.
        //
        // This is the half that covers the doors that are actually open, and
        // none of them is a menu item: `toggleToolbarShown:` reaches any
        // window from anywhere in the responder chain, the title bar has a
        // context menu of AppKit's own, and *state restoration* remembers
        // toolbar visibility across launches — so without this, a window
        // hidden once would reopen hidden for good. `IllogicalApp` empties the
        // `.toolbar` command group as well, which is belt to this braces and
        // is measured to delete nothing today; see the note there.
        //
        // On every update rather than only at creation, because a restored
        // window arrives after both. Written only when it is wrong, so this is
        // not a set on every pass of a SwiftUI body — including the ones in
        // the middle of a live resize.
        if window.toolbar?.isVisible == false { window.toolbar?.isVisible = true }

        if let existing = context.coordinator.accessory {
            // Keep the hosted SwiftUI view current across state changes.
            (existing.view as? NSHostingView<Toolbar>)?.rootView = toolbar()
            return
        }

        // An empty toolbar, for its *height* and nothing else.
        //
        // A `.top` accessory is placed inside `NSTitlebarView`, and that view is
        // a fixed 32pt on a plain window. AppKit hands the accessory to an
        // `NSTitlebarAccessoryClipView` sized to the titlebar and resizes the
        // hosted view down to fit, so `Metrics.toolbarHeight` was being asked
        // for and quietly clipped: the strip drew 32pt of its 39 and the tab
        // pill sat a point and a half under the top of the window with two
        // points below it, where the reference gives it five and six. The
        // SwiftUI side was never wrong — `NSHostingView.intrinsicContentSize`
        // reported the full 39 throughout.
        //
        // Attaching a toolbar in `.unifiedCompact` makes that band 40pt, and
        // the accessory then gets all of it. The reference is built the same
        // way, which is checkable rather than assumed: a unified titlebar
        // shifts the traffic lights right by 3pt, and the reference's first
        // light sits 20.0pt from the window's left edge where a plain titlebar
        // puts it at 16.0 and this puts it at 19.0.
        //
        // No items and no delegate, so it contributes nothing to draw. The
        // accessory covers the full width and paints `Palette.toolbar` over it.
        //
        // What it does contribute is a way to *lose* the band, which is what
        // the heal above is for: `allowsUserCustomization` covers the
        // customize sheet, and nothing here covers `toggleToolbarShown:` or a
        // window restored with the toolbar already off.
        let spacer = NSToolbar(identifier: "illogical.titlebar-height")
        spacer.allowsUserCustomization = false
        window.toolbar = spacer
        window.toolbarStyle = .unifiedCompact

        let hosting = NSHostingView(rootView: toolbar())
        hosting.frame = NSRect(x: 0, y: 0, width: window.frame.width, height: toolbarHeight)
        hosting.autoresizingMask = [.width]

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = hosting
        accessory.layoutAttribute = .top
        // What this asks for: that the strip stay on screen in full screen,
        // where AppKit otherwise takes the whole title bar away until the
        // pointer goes to the top of the display. At 0 — the default — an
        // accessory goes with it; at a height it stays behind at that height.
        //
        // It was written for a window with no toolbar, and the toolbar above
        // has since put the accessory in a title bar with a second reason to
        // auto-hide, so it was worth measuring rather than reasoning about.
        // **Measured**, on macOS 26: driven into full screen with the pointer
        // parked well away from the top and read back ten seconds later, the
        // accessory is un-hidden at alpha 1, its full 40pt tall, flush with
        // the top of the window — and it is all of that with this line set to
        // `0` as well. So the toolbar has not made the strip auto-hide, and
        // this line is not what is holding it up: a `.hiddenTitleBar` window
        // whose title bar is transparent appears to keep its accessory either
        // way.
        //
        // Kept anyway. It is the documented way to ask for what the app wants
        // and it costs a property set, where "it holds without asking" is a
        // fact about one OS version — deleting it trades a line for something
        // to rediscover.
        accessory.fullScreenMinHeight = toolbarHeight
        window.addTitlebarAccessoryViewController(accessory)
        context.coordinator.accessory = accessory
    }
}

/// Blurring what shows through the window, the way Ghostty does it.
///
/// `CGSSetWindowBackgroundBlurRadius` is a private CoreGraphics call, and the
/// reason to reach for one is that the public alternative is a different
/// feature wearing the same word. `NSVisualEffectView` blurs behind a *view*,
/// at a radius the system picks, and tints what it blurs with a material —
/// which is right for a sidebar and wrong for a terminal, where the point is
/// that the wallpaper is dimmer and softer, not that it has been recoloured.
/// It is also why `background-blur` can take a radius here at all: with the
/// effect view there would be no number to honour.
///
/// Resolved with `dlsym` rather than declared with `@_silgen_name`, which is
/// what Ghostty uses. The two produce the same call; the difference is what
/// happens on the macOS that finally drops the symbol. A `@_silgen_name`
/// declaration is a link-time reference, so the app would fail to launch at
/// all — over a blur. This way the lookup returns nil, the window is
/// unblurred, and the terminal opens.
enum WindowBlur {
    /// `(connection ID, window number, radius) -> OSStatus`.
    private typealias SetRadius = @convention(c) (UInt32, UInt32, Int32) -> Int32
    private typealias DefaultConnection = @convention(c) () -> UInt32

    /// Looked up once. `RTLD_DEFAULT` is `-2` on Darwin: search every image
    /// already loaded, which CoreGraphics always is.
    private static let entryPoints: (connection: DefaultConnection, setRadius: SetRadius)? = {
        let global = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(global, "CGSDefaultConnectionForThread"),
            let setRadius = dlsym(global, "CGSSetWindowBackgroundBlurRadius")
        else {
            Trace.log("background blur unavailable: CGS symbols not found")
            return nil
        }
        return (
            unsafeBitCast(connection, to: DefaultConnection.self),
            unsafeBitCast(setRadius, to: SetRadius.self)
        )
    }()

    /// Blur `radius` pixels of whatever is behind `window`.
    ///
    /// Behind the *window*, so this is only visible where the window is
    /// see-through — which is the terminal and nothing else, since every
    /// piece of chrome paints its own opaque background. That is what makes
    /// one window-wide call the right shape for a per-terminal setting.
    static func apply(radius: Int, to window: NSWindow) {
        guard radius > 0, let entryPoints else { return }
        // Zero until the window is on screen, and a blur set against it goes
        // nowhere. Every caller here runs from a `DispatchQueue.main.async`
        // after the window exists, so this is a guard rather than a wait.
        guard window.windowNumber > 0 else { return }
        let status = entryPoints.setRadius(
            entryPoints.connection(), UInt32(window.windowNumber), Int32(radius))
        if status != 0 { Trace.log("background blur refused: status \(status)") }
    }
}
