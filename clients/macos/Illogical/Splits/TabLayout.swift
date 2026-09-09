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
/// Arithmetic, and it lives here rather than in `Chrome.swift` for the same
/// reason `SplitTree` is not inside `SplitContainer.swift`: arithmetic is
/// testable without a window. The gesture plumbing around these functions
/// cannot be simulated at all, so the least that can be done is to leave
/// nothing else inside it — every question a drag asks is answered here and
/// pinned by `TabOrderTests`.
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

    /// How far the dragged slot has actually come, held inside the strip.
    ///
    /// A native tab bar does not let a tab leave the strip: it stops against
    /// the first slot and against the last one rather than following the
    /// pointer out over `+` and off the window. Without this the tab and the
    /// slot it would land in came apart the moment `dropIndex` clamped — you
    /// were dragging a tab through the toolbar while the strip had long since
    /// stopped listening, which is most of why reordering read as broken.
    static func clampedTranslation(
        from index: Int, translation: CGFloat, slotWidth: CGFloat, count: Int
    ) -> CGFloat {
        guard count > 0, slotWidth > 0, translation.isFinite,
            index >= 0, index < count
        else { return 0 }
        let leftmost = -CGFloat(index) * slotWidth
        let rightmost = CGFloat(count - 1 - index) * slotWidth
        return min(max(translation, leftmost), rightmost)
    }

    /// The slots in the order they are *drawn* while a tab is in flight: the
    /// order the strip would be in if the drag ended on this frame.
    ///
    /// This is what makes the neighbours slide. The strip used to hold still
    /// under a drag and outline the slot the tab would land in, which is two
    /// things a tab bar does not do — the outline named a slot that was
    /// already occupied, and the tab you were dragging passed *over* its
    /// neighbours rather than through them. Drawing in this order instead,
    /// every slot but the dragged one sits at its would-be position, so the
    /// gap under the pointer is the answer and there is nothing left to
    /// annotate.
    ///
    /// Returns slot indices by drawn position, so `displayOrder(...)[2]` is
    /// the slot drawn third. Identity when nothing is being dragged.
    static func displayOrder(count: Int, from: Int?, to: Int?) -> [Int] {
        var order = Array(0..<max(0, count))
        guard let from, let to, from != to,
            order.indices.contains(from), order.indices.contains(to)
        else { return order }
        order.insert(order.remove(at: from), at: to)
        return order
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
