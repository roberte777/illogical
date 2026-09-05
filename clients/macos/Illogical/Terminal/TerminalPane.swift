//  TerminalPane.swift
//  Hosts one terminal surface and connects it to its controller.
//
//  A split view would hold several of these, each with its own connection to
//  its own PTY. There is no in-window multiplexing: the server never divides a
//  grid. See docs/ARCHITECTURE.md.

import AppKit
import IllogicalProtocol
import SwiftUI

struct TerminalPane: View {
    @Environment(SessionStore.self) private var store
    let terminal: TerminalSummary

    var body: some View {
        TerminalSurface(terminal: terminal)
            .environment(store)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
    }
}

struct TerminalSurface: NSViewRepresentable {
    @Environment(SessionStore.self) private var store
    let terminal: TerminalSummary

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, terminalID: terminal.id)
    }

    func makeNSView(context: Context) -> TerminalSurfaceView {
        let view = TerminalSurfaceView(frame: .zero)
        view.delegate = context.coordinator
        view.statusText = "attaching…"
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: TerminalSurfaceView, context: Context) {}

    @MainActor
    final class Coordinator: TerminalSurfaceDelegate {
        private let store: SessionStore
        private let terminalID: UInt64
        weak var view: TerminalSurfaceView?
        private var controller: TerminalController?

        init(store: SessionStore, terminalID: UInt64) {
            self.store = store
            self.terminalID = terminalID
        }

        func surfaceIsReady(_ surface: TerminalSurfaceView) {
            attach(into: surface)
        }

        private func attach(into view: TerminalSurfaceView) {
            guard controller == nil else { return }
            let size = view.gridSize
            guard
                let controller = store.controller(
                    for: terminalID, cols: size.cols, rows: size.rows)
            else {
                view.statusText = "could not attach"
                return
            }
            self.controller = controller
            view.engine = controller.engine
            view.statusText = nil
            view.needsDisplay = true
            Trace.log("attached to terminal \(terminalID) at \(size.cols)x\(size.rows)")
            if let path = ProcessInfo.processInfo.environment["ILLOGICAL_DUMP_PNG"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    view.dumpPNG(to: path)
                    Trace.log("dumped \(path)")
                }
            }
        }

        func surface(_ surface: TerminalSurfaceView, send bytes: [UInt8]) {
            controller?.send(bytes)
        }

        func surface(_ surface: TerminalSurfaceView, resizeTo cols: UInt16, rows: UInt16) {
            controller?.resize(cols: cols, rows: rows)
        }

        func surface(_ surface: TerminalSurfaceView, scrollWheel event: NSEvent) {
            // Only reached when an alternate-screen program owns the wheel;
            // the surface has already decided that.
            guard let controller else { return }
            let rows = Int(event.scrollingDeltaY.rounded())
            guard rows != 0 else { return }
            let sequence = rows > 0 ? "\u{1b}[A" : "\u{1b}[B"
            for _ in 0..<min(abs(rows), 5) {
                controller.send(Array(sequence.utf8))
            }
        }
    }
}
