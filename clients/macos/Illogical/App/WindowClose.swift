//  WindowClose.swift
//  The half of closing that a store cannot do.
//
//  `SessionStore` owns the policy — which pane goes, which tab goes, whether to
//  ask first — and is deliberately window-free so all of that is testable
//  without one. But every close has a last case where the answer is "there is
//  nothing left to show, so the window goes", and only a view can send that.
//
//  One file so the three places a close starts from — ⌘W's responder path is
//  the fourth and lives in `TerminalSurfaceView` — cannot drift apart. They
//  did: ⌘W on the last terminal closed the window and left the shell running,
//  while ⇧⌘W and the tab strip's ✕ on the same terminal hung it up and left an
//  empty window behind.
//
//  Closing the window is not destructive here. The terminals keep running on
//  the server; the empty state says so in as many words, and re-launching
//  re-attaches to them. That is why this path never confirms.

import AppKit

@MainActor
enum WindowClose {
    /// ⇧⌘W, and the ✕ on a tab in the strip.
    static func tab(_ id: TabLayout.ID, in store: SessionStore) {
        if store.requestCloseTab(id) == .closeWindow { window() }
    }

    /// The ✕ in a pane's own header, which is ⌘W for that pane — including
    /// the case where that pane was the last thing in the window.
    static func pane(_ paneID: UUID, in tab: TabLayout.ID, of store: SessionStore) {
        if !store.closeSurfacePane(paneID, in: tab) { window() }
    }

    /// `performClose:` rather than `close()`: it runs `windowShouldClose`,
    /// animates, and is what the standard Close item sends — a click on a ✕
    /// should be indistinguishable from the chord it advertises.
    private static func window() {
        (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first)?.performClose(nil)
    }
}
