//  TabLayout.swift
//  One tab: a layout of panes, each its own connection to its own PTY.
//
//  A tab has an identity of its own rather than being named by a terminal.
//  That matters as soon as splits exist: a tab named by the terminal it
//  started as has nothing to be called once you close that pane and keep
//  working in the other one.

import CoreGraphics
import Foundation

/// The tab strip's geometry, apart from the view that draws it.
///
/// One function, and it lives here rather than in `Chrome.swift` for the same
/// reason `SplitTree` is not inside `SplitContainer.swift`: it is arithmetic,
/// and arithmetic is testable without a window. Turning a drag's translation
/// into a slot is the only part of drag-to-reorder that can be wrong in a way a
/// test can catch — the gesture plumbing around it cannot be simulated at all,
/// so the least that can be done is to leave nothing else inside it.
enum TabStrip {
    /// The slot a tab dragged from `index` by `translation` points at.
    ///
    /// Rounded rather than truncated: a tab dragged more than half a slot has
    /// visibly passed its neighbour, and that is the moment it should take its
    /// place. Clamped to the strip, so dragging off either end parks it at that
    /// end instead of doing nothing.
    static func dropIndex(
        from index: Int, translation: CGFloat, slotWidth: CGFloat, count: Int
    ) -> Int {
        guard count > 0, slotWidth > 0, translation.isFinite else { return index }
        let slots = Int((translation / slotWidth).rounded())
        return min(max(index + slots, 0), count - 1)
    }
}

struct TabLayout: Identifiable, Equatable {
    let id: UUID
    /// The session this tab belongs to, on the machine that session lives on.
    /// A tab never spans two hosts: a session is a thing that exists on one.
    var session: SessionRef
    var root: SplitNode
    /// The pane input goes to, and whose terminal names the tab.
    var focused: UUID
    /// A pane temporarily filling the tab, hiding the rest of the tree.
    var zoomed: UUID?

    init(session: SessionRef, terminal: TerminalRef) {
        let pane = Pane(terminal: terminal)
        self.id = UUID()
        self.session = session
        self.root = .leaf(pane)
        self.focused = pane.id
        self.zoomed = nil
    }

    var panes: [Pane] { root.panes }
    var isSplit: Bool { !root.isLeaf }
    var focusedTerminal: TerminalRef? { root.pane(focused)?.terminal }

    /// Put focus somewhere valid after the tree changed under it.
    mutating func repairFocus() {
        if root.pane(focused) == nil { focused = root.panes.first?.id ?? focused }
        if let zoomed, root.pane(zoomed) == nil { self.zoomed = nil }
    }
}
