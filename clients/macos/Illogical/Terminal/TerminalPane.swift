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

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane, tab: tab, isFocused: isFocused)
                .environment(store)
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
        .background(Palette.background)
        .traceFrame("pane-\(pane.terminal.terminal)")
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
            let size = view.gridSize
            guard
                let controller = store.controller(
                    for: terminal, cols: size.cols, rows: size.rows)
            else {
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
            controller.resize(cols: size.cols, rows: size.rows)
            Trace.log(
                "attached to \(terminal.host.displayName) terminal \(terminal.terminal) "
                    + "at \(size.cols)x\(size.rows)")
        }

        func surface(_ surface: TerminalSurfaceView, send bytes: [UInt8]) {
            controller?.send(bytes)
        }

        func surface(_ surface: TerminalSurfaceView, resizeTo cols: UInt16, rows: UInt16) {
            controller?.resize(cols: cols, rows: rows)
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
