//  TerminalPane.swift
//  One pane: a header and a surface, holding one connection to one PTY.
//
//  A tab showing four splits holds four of these and four protocol
//  connections. There is no in-window multiplexing and no layout protocol —
//  the server never divides a grid. See docs/ARCHITECTURE.md.

import AppKit
import IllogicalProtocol
import SwiftUI

struct TerminalPane: View {
    @Environment(SessionStore.self) private var store
    let pane: Pane
    let tab: TabLayout.ID

    private var isFocused: Bool {
        store.tabs.first { $0.id == tab }?.focused == pane.id
    }

    /// What the header sits on: the terminal's own background, at the
    /// terminal's own opacity.
    ///
    /// Read once. `background-opacity` does not change while the app runs
    /// (#39) and this is a `body`. Left as the plain colour at 1 rather than
    /// `.opacity(1)`, so the ordinary case is the same value the surface
    /// itself paints and no alpha ever enters the comparison.
    private static let cardBackground: Color = {
        let alpha = AppConfig.current.backgroundOpacity
        return alpha >= 1 ? Palette.background : Palette.background.opacity(alpha)
    }()

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane, tab: tab, isFocused: isFocused)
                .environment(store)
                // The terminal's own background, at the terminal's own
                // opacity: the breadcrumb is *inside* the card, so it reads as
                // part of the surface it names rather than as a strip of
                // chrome above it.
                //
                // Behind the header only, and never behind the whole pane.
                // The surface paints this same colour itself, so a second
                // translucent layer under it would multiply into a third
                // opacity nobody asked for — 0.8 twice is 0.96.
                .background(Self.cardBackground)
            // `focusGeneration` is read *here*, in a body, so the store's
            // observation registers it. Handing it to the representable is
            // what guarantees an `updateNSView` when something — the session
            // menu closing — asks for the keyboard back; a representable
            // whose inputs did not change need not be updated at all.
            TerminalSurface(pane: pane, tab: tab, focusGeneration: store.focusGeneration)
                .environment(store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Over the terminal, not instead of it. The screen underneath
                // is the last thing this terminal showed and still the best
                // guess at what it shows — the far side never stopped.
                .overlay(alignment: .top) {
                    if let controller = store.existingController(for: pane.terminal) {
                        ConnectionBanner(
                            state: controller.state,
                            host: pane.terminal.host,
                            retry: { controller.retryNow() })
                    }
                }
                // The find bar, over the same surface and for the same reason
                // the banner is: a bar that pushed the grid down would resize
                // the PTY and reflow the screen being searched every time ⌘F
                // was pressed.
                .overlay {
                    if let controller = store.existingController(for: pane.terminal) {
                        FindOverlay(session: controller.search)
                    }
                }
        }
        // The bezel, around the whole pane rather than around the surface
        // alone. The breadcrumb goes inside the card with the terminal it
        // names — the cwd, the command and the split controls all belong to
        // that terminal, and a header sitting out on the frame would read as
        // belonging to the window.
        //
        // Three sides. The top edge is flush against the toolbar, and the
        // card's own border is what divides them; see `Metrics.terminalInset`.
        .clipShape(
            RoundedRectangle(
                cornerRadius: Metrics.terminalCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: Metrics.terminalCornerRadius, style: .continuous
            )
            .strokeBorder(Palette.divider, lineWidth: Metrics.terminalBorderWidth)
        }
        .padding(.horizontal, Metrics.terminalInset)
        .padding(.bottom, Metrics.terminalInset)
        .background { Bezel() }
        .traceFrame("pane-\(pane.terminal.terminal)")
    }
}

/// The chrome the terminal is inset into: everything inside this view except
/// the card itself.
///
/// A ring, and not a rectangle behind the card, which is the whole reason it
/// is a `Path` rather than a colour. A translucent terminal shows whatever is
/// painted behind it, so a chrome-coloured fill under the card is precisely
/// the thing `background-opacity` would then show you — the frame, at 20%,
/// instead of your desktop. Measured the hard way: the first version of this
/// was `.background(Palette.toolbar)` on the pane, and a window set to 0.8
/// opacity was pixel-identical to one set to 1.
///
/// Sized to the padded pane, so the hole and the card are laid out by the same
/// numbers rather than by two copies of them.
private struct Bezel: View {
    var body: some View {
        GeometryReader { geometry in
            let card = CGRect(
                x: Metrics.terminalInset,
                y: 0,
                width: max(0, geometry.size.width - 2 * Metrics.terminalInset),
                height: max(0, geometry.size.height - Metrics.terminalInset))
            Path { path in
                path.addRect(CGRect(origin: .zero, size: geometry.size))
                path.addRoundedRect(
                    in: card,
                    cornerSize: CGSize(
                        width: Metrics.terminalCornerRadius,
                        height: Metrics.terminalCornerRadius),
                    style: .continuous)
            }
            // Even-odd: the second subpath punches the first rather than
            // adding to it.
            .fill(Palette.toolbar, style: FillStyle(eoFill: true))
        }
    }
}

/// The find bar and the space it floats in.
///
/// A `GeometryReader` rather than an alignment, because the bar's position is
/// not a constant: it starts at the top right and moves down past whatever the
/// search found underneath it, and working that out needs the surface's own
/// size in the same coordinates the matches are measured in.
struct FindOverlay: View {
    let session: SearchSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            // The container is unconditional so the *removal* transition has
            // something to run inside — the same shape `ConnectionBanner` uses.
            ZStack(alignment: .topLeading) {
                if session.isOpen {
                    SearchBar(session: session, surface: geometry.size)
                        .transition(Motion.search.transition(reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(
                Motion.search.animation(reduceMotion: reduceMotion), value: session.isOpen)
        }
        // Only the bar takes the mouse. Without this the reader would swallow
        // every click meant for the terminal underneath it.
        .allowsHitTesting(session.isOpen)
    }
}

/// A pill over the terminal while its connection is being made again.
///
/// Not an error sheet, and not a blank screen. A network that went away comes
/// back; the terminal on the far side never stopped, and re-attaching is
/// O(screen). The right shape for that is a note, not an interruption.
struct ConnectionBanner: View {
    let state: TerminalController.State
    let host: ServerHost
    let retry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String? {
        switch state {
        case .reconnecting:
            host.isRemote ? "Reconnecting to \(host.displayName)…" : "Reconnecting…"
        case .failed(let message): message
        case .connecting, .attaching, .live, .exited: nil
        }
    }

    var body: some View {
        // The container is unconditional so the pill has something to leave
        // from: with the `if` at the top of `body` the view is simply gone the
        // instant the connection comes back, and a removal transition has
        // nowhere to run.
        ZStack(alignment: .top) {
            if let text {
                pill(text)
                    .transition(Motion.banner.transition(reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.banner.animation(reduceMotion: reduceMotion), value: text)
    }

    private func pill(_ text: String) -> some View {
        HStack(spacing: 8) {
            if state.isReconnecting {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textBright)
                .lineLimit(1)
            Button("Retry", action: retry)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.menuHighlight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Palette.toolbar)
                .overlay(Capsule().strokeBorder(Palette.divider, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        )
        .padding(.top, 10)
        .accessibilityLabel(Text(text))
    }
}

struct TerminalSurface: NSViewRepresentable {
    @Environment(SessionStore.self) private var store
    let pane: Pane
    let tab: TabLayout.ID
    /// `SessionStore.focusGeneration`. Not read here for its value — only so
    /// that a bump changes this representable and forces `updateNSView`, which
    /// is where first responder is re-asserted.
    var focusGeneration: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, terminal: pane.terminal, pane: pane.id, tab: tab)
    }

    func makeNSView(context: Context) -> TerminalSurfaceView {
        let view = TerminalSurfaceView(frame: .zero)
        view.delegate = context.coordinator
        view.statusText = "attaching…"
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: TerminalSurfaceView, context: Context) {
        context.coordinator.store = store
        // Not while this pane's find bar is up. The field holds first responder
        // for as long as it is open, and this runs on *every* update — so
        // anything that touches the store while you are typing a query would
        // take the keyboard back mid-word and put the rest of it into the
        // shell. Read rather than observed on purpose: this is a question about
        // right now, not an input the view needs rebuilding for.
        guard store.existingController(for: pane.terminal)?.search.isOpen != true else { return }
        // Nor while the dropdown or the palette is up, for the same reason:
        // each has a field that holds first responder for as long as the panel
        // is on screen. This runs whenever SwiftUI updates the representable,
        // not only when `focusGeneration` asks — a terminal appearing on any
        // machine rewrites `tabs`, which is read below — and each of those
        // updates took the keyboard back from the panel. The filter could not
        // be typed into and Return, which the field reads as `.onSubmit`, went
        // to the shell, while the arrows went on working, because `PaletteKeys`
        // takes them before first responder is consulted — so the panel looked
        // as though it had the keyboard when it did not. Closing either one
        // lifts this, and `ContentView` bumps `focusGeneration` besides.
        guard !store.overlayHoldsKeyboard else { return }
        // The tab may have moved focus without a click — a keyboard move, or
        // the pane the tree collapsed onto. AppKit is the authority on first
        // responder, so tell it rather than tracking focus separately.
        if store.tabs.first(where: { $0.id == tab })?.focused == pane.id,
            view.window?.firstResponder !== view
        {
            view.window?.makeFirstResponder(view)
        }
    }

    @MainActor
    final class Coordinator: TerminalSurfaceDelegate {
        var store: SessionStore
        private let terminal: TerminalRef
        private let pane: UUID
        private let tab: TabLayout.ID
        weak var view: TerminalSurfaceView?
        private var controller: TerminalController?

        init(store: SessionStore, terminal: TerminalRef, pane: UUID, tab: TabLayout.ID) {
            self.store = store
            self.terminal = terminal
            self.pane = pane
            self.tab = tab
        }

        func surfaceIsReady(_ surface: TerminalSurfaceView) {
            attach(into: surface)
        }

        private func attach(into view: TerminalSurfaceView) {
            guard controller == nil else { return }
            let size = view.surfaceSize
            guard let controller = store.controller(for: terminal, size: size) else {
                view.statusText = "could not attach"
                return
            }
            self.controller = controller
            view.engine = controller.engine
            // The find bar measures its dodge in this surface's coordinates,
            // and rebinds here rather than holding one for the terminal's life:
            // a split, a close or a zoom builds a new surface over the same
            // engine, and the matches have to be measured in the one on screen.
            controller.search.bind(surface: view)
            view.statusText = nil
            view.needsDisplay = true
            // The size travels in the attach — but only for a controller this
            // call *made*. A split, a zoom, or a pane closing builds a new
            // surface over a controller that is already connected, and that one
            // is still at the geometry of the pane it used to fill: half a
            // window wide after a ⌘D, a whole window wide after an unzoom. A
            // surface's first layout is exempt from `reportSizeIfNeeded`, so
            // without this nothing ever tells the terminal, and the pane draws
            // a grid twice its width with the right-hand half past the edge.
            // A no-op when the attach above already carried this size.
            controller.resize(size)
            Trace.log(
                "attached to \(terminal.host.displayName) terminal \(terminal.terminal) "
                    + "at \(size.cols)x\(size.rows)")
        }

        func surface(_ surface: TerminalSurfaceView, send bytes: [UInt8]) {
            controller?.send(bytes)
        }

        func surface(_ surface: TerminalSurfaceView, resizeTo size: SurfaceSize) {
            controller?.resize(size)
        }

        /// AppKit is the authority on which pane has focus; the tab follows it
        /// rather than the other way round, so a click lands where it looks
        /// like it landed.
        func surfaceDidBecomeFocused(_ surface: TerminalSurfaceView) {
            store.focus(pane, in: tab)
        }

        func surface(_ surface: TerminalSurfaceView, didPresentFirstFrameAt moment: Date) {
            controller?.didPresentFirstFrame(at: moment)
        }

        /// The policy is `SessionStore.closeSurfacePane`, not this method:
        /// this file has no test target, and "does ⌘W close the window" is
        /// exactly the question worth a test (#41).
        func surfaceShouldClose(_ surface: TerminalSurfaceView) -> Bool {
            store.closeSurfacePane(pane, in: tab)
        }
    }
}
