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
        }
        .background(Palette.background)
        .traceFrame("pane-\(pane.terminal.terminal)")
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
            view.statusText = nil
            view.needsDisplay = true
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
