//  TerminalSurface.swift
//  The NSView that draws a session.
//
//  SCAFFOLD. The renderer is the largest remaining piece of the client:
//  libghostty-vt hands us grid state via `ghostty_render_state_*` (see
//  example/c-vt-render in vendor/ghostty), and this view is responsible for
//  turning that into pixels — a CoreText-rasterized glyph atlas drawn with
//  Metal, plus native scrollback driven by the view's own scroll events rather
//  than by synthesizing wheel escape sequences.
//
//  See docs/ROADMAP.md M3.

import AppKit
import SwiftUI

/// Hosts the Metal-backed terminal renderer.
final class TerminalSurfaceView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // TODO(M3): replace with the Metal renderer fed by ghostty_render_state_*.
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        let message = "terminal renderer not implemented yet — see docs/ROADMAP.md M3"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = message.size(withAttributes: attributes)
        message.draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            ),
            withAttributes: attributes
        )
    }
}

struct TerminalSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalSurfaceView { TerminalSurfaceView() }
    func updateNSView(_ nsView: TerminalSurfaceView, context: Context) {}
}
