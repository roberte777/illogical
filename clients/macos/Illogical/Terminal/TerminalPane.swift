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
            TerminalSurface(pane: pane, tab: tab)
                .environment(store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.background)
        .traceFrame("pane-\(pane.terminal.terminal)")
    }
}

struct TerminalSurface: NSViewRepresentable {
    @Environment(SessionStore.self) private var store
    let pane: Pane
    let tab: TabLayout.ID

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

        func surfaceShouldClose(_ surface: TerminalSurfaceView) -> Bool {
            guard let tab = store.tabs.first(where: { $0.id == tab }), tab.isSplit else {
                return false
            }
            store.closePane(pane, in: tab.id)
            return true
        }
    }
}
