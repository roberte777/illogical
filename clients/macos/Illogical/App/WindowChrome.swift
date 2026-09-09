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

/// Reports where the pointer is over this view, in the view's own coordinates,
/// and when it leaves it.
///
/// A local `NSEvent` monitor, which is a strange way to ask "is the pointer
/// over this view" and is the only way that answers on the tab strip. Both
/// ordinary ways stop reporting to a slot the moment a drag ends on it —
/// SwiftUI's `onHover` and `onContinuousHover`, and an `NSTrackingArea` on the
/// same view, all of them — and they stay silent until the pointer leaves the
/// window and comes back. Every drop ends a drag under the pointer, so that is
/// exactly when the strip needs an answer and exactly when it stops getting
/// one: the ✕ froze on the tab you had just dropped.
///
/// Measured rather than reasoned, after three fixes that reasoned their way to
/// the wrong mechanism. In one reproduction, after the drop: 0 events from the
/// tracking area, 0 from SwiftUI's hover, 390 from the monitor. The window
/// never stopped *generating* the events — delivery to the view is what breaks
/// — so a monitor, which watches the events the app dispatches rather than the
/// ones a view is offered, sees all of them.
///
/// The `NSView` is only a ruler: it converts a window point into the strip's
/// own coordinates and contributes nothing else, which is why it answers
/// `hitTest` with nil and takes no part in where a click lands.
///
/// Needs `window.acceptsMouseMovedEvents`, which `configure` sets — without it
/// the window makes no mouse-moved events for anyone to monitor.
struct PointerTracker: NSViewRepresentable {
    /// Where the pointer is, in the tracked view's own coordinates.
    let moved: (CGPoint) -> Void
    /// The pointer is somewhere else.
    let exited: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(moved: moved, exited: exited)
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.moved = moved
        nsView.exited = exited
    }

    final class TrackingView: NSView {
        var moved: (CGPoint) -> Void
        var exited: () -> Void
        private var monitor: Any?

        init(moved: @escaping (CGPoint) -> Void, exited: @escaping () -> Void) {
            self.moved = moved
            self.exited = exited
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("PointerTracker is not built from a nib") }

        /// Never the view a click lands on. It goes in as a `.background` under
        /// live controls and only wants the geometry, so it stays out of hit
        /// testing entirely.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The monitor lives exactly as long as the view is in a window, which
        /// is the only span in which it has coordinates to report.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) {
                [weak self] event in
                self?.observe(event)
                return event
            }
        }

        /// Watched, never intercepted: `observe` is called from a monitor that
        /// returns the event unchanged, so nothing downstream of it sees a
        /// difference.
        private func observe(_ event: NSEvent) {
            guard let window, event.window === window else { return exited() }
            let point = convert(event.locationInWindow, from: nil)
            // Horizontally the strip's own arithmetic would catch a point past
            // either end, but nothing else would catch one above or below it.
            guard bounds.contains(point) else { return exited() }
            moved(point)
        }
    }
}

extension View {
    /// Follow the pointer across this view. See `PointerTracker` for why this
    /// is not `onHover`.
    func tracksPointer(
        moved: @escaping (CGPoint) -> Void, exited: @escaping () -> Void
    ) -> some View {
        background(PointerTracker(moved: moved, exited: exited))
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

        // Without this the window generates no mouse-moved events, and every
        // consumer of them in the title bar accessory is left with enters and
        // exits only. Traced: the tab strip saw hundreds of moves before a
        // drag and two after one, because SwiftUI turns this on for its own
        // hover tracking and does not leave it on. `NSTrackingArea` asking for
        // `.mouseMoved` does not turn it on either -- a tracking area says
        // where an event is delivered, not whether the window makes one.
        window.acceptsMouseMovedEvents = true

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
