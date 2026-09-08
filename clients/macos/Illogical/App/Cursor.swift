//  Cursor.swift
//  A pointer of this view's own, for the overlays drawn over the terminal.
//
//  The terminal surface claims an I-beam across its whole bounds -- see
//  `TerminalSurfaceView.resetCursorRects` -- because that is what a terminal
//  is: text to select. Anything the app draws *over* it inherits that claim,
//  and AppKit is right to let it: a cursor rect is resolved against the
//  frontmost view that has one, and an ordinary SwiftUI view has none. So the
//  session dropdown's rows came up under an I-beam and read as text to select
//  rather than as something to click.
//
//  A cursor *rect* rather than `NSCursor.push()` from `.onHover`, which is what
//  the split divider uses. Push and pop have to be paired, and an overlay's
//  `onHover(false)` does not arrive for a view that has already gone -- the
//  session menu closes under the pointer, because that is what clicking a row
//  does. The pop never runs, and the pushed cursor is left on the stack over
//  the terminal afterwards. A rect belongs to the view, goes when the view
//  goes, and has no pairing to get wrong.

import AppKit
import SwiftUI

/// An empty view whose only job is to own a cursor rect.
struct CursorRect: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> NSView { CursorView(cursor: cursor) }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? CursorView, view.cursor != cursor else { return }
        view.cursor = cursor
        // The rects are cached by the window until something says otherwise,
        // so a cursor that changes after the view is on screen needs this or
        // it keeps the pointer it was built with.
        view.window?.invalidateCursorRects(for: view)
    }

    private final class CursorView: NSView {
        var cursor: NSCursor

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not built from a nib") }

        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    }
}

extension View {
    /// The pointer to show over this view. See the note above for why an
    /// overlay over the terminal has to say so at all.
    ///
    /// A background rather than an overlay, so that it does not take the
    /// clicks its view is there to receive, and so that a nested `cursor(_:)`
    /// -- the I-beam the dropdown's filter field puts back over the panel's
    /// arrow -- is in front and wins the part it covers.
    func cursor(_ cursor: NSCursor) -> some View {
        background(CursorRect(cursor: cursor))
    }
}
