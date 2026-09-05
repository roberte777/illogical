//  SplitTree.swift
//  The layout of one tab: a binary tree of panes.
//
//  This is the entire "split protocol", and it is deliberately local. The
//  server never divides a grid and knows nothing about layout — a window
//  showing four splits holds four ordinary connections to four PTYs, and
//  closing a split is closing a connection. See docs/GOALS.md.
//
//  A value type, so a layout change is one assignment the view layer can
//  diff, and so the tests can build a tree without a terminal, a socket or a
//  window.

import Foundation

/// One terminal in a layout.
///
/// The pane has an identity of its own rather than being keyed by terminal:
/// the same terminal could in principle appear twice, and a pane outlives the
/// moment its terminal is created — a split shows a pane before the server has
/// answered with an id.
struct Pane: Identifiable, Equatable {
    let id: UUID
    var terminalID: UInt64

    init(id: UUID = UUID(), terminalID: UInt64) {
        self.id = id
        self.terminalID = terminalID
    }
}

indirect enum SplitNode: Identifiable, Equatable {
    case leaf(Pane)
    case split(Split)

    /// Named for what the children do, not for the divider, because
    /// "horizontal split" means opposite things in tmux and in every GUI.
    enum Direction: Equatable {
        /// Side by side, divided by a vertical line.
        case columns
        /// Stacked, divided by a horizontal line.
        case rows
    }

    struct Split: Identifiable, Equatable {
        let id: UUID
        var direction: Direction
        /// The first child's share of the long axis, clamped away from the
        /// edges so a pane can always be grabbed back.
        var ratio: Double
        var first: SplitNode
        var second: SplitNode

        static let minimumRatio = 0.1
        static let maximumRatio = 0.9
    }

    var id: UUID {
        switch self {
        case .leaf(let pane): pane.id
        case .split(let split): split.id
        }
    }

    /// Every pane, left to right and top to bottom.
    var panes: [Pane] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(let split): split.first.panes + split.second.panes
        }
    }

    var isLeaf: Bool {
        if case .leaf = self { return true }
        return false
    }

    func pane(_ id: UUID) -> Pane? {
        panes.first { $0.id == id }
    }

    func pane(forTerminal terminalID: UInt64) -> Pane? {
        panes.first { $0.terminalID == terminalID }
    }

    // MARK: - Editing

    /// Replace the leaf holding `pane` with a split of it and `newPane`.
    ///
    /// The new pane goes second: splitting right puts it on the right,
    /// splitting down puts it below, which is what both icons draw.
    func splitting(
        _ paneID: UUID, with newPane: Pane, direction: Direction, ratio: Double = 0.5
    ) -> SplitNode {
        switch self {
        case .leaf(let pane):
            guard pane.id == paneID else { return self }
            return .split(
                Split(
                    id: UUID(), direction: direction, ratio: ratio,
                    first: .leaf(pane), second: .leaf(newPane)))

        case .split(var split):
            split.first = split.first.splitting(
                paneID, with: newPane, direction: direction, ratio: ratio)
            split.second = split.second.splitting(
                paneID, with: newPane, direction: direction, ratio: ratio)
            return .split(split)
        }
    }

    /// Remove a pane, collapsing the split that held it. Nil when the pane
    /// was the last one, which means the tab itself is going away.
    func removing(_ paneID: UUID) -> SplitNode? {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID ? nil : self

        case .split(var split):
            if let first = split.first.removing(paneID) {
                split.first = first
            } else {
                return split.second
            }
            if let second = split.second.removing(paneID) {
                split.second = second
            } else {
                return split.first
            }
            return .split(split)
        }
    }

    /// Move a divider. Clamped, because a zero-width pane is a pane you
    /// cannot get back.
    func settingRatio(_ ratio: Double, forSplit splitID: UUID) -> SplitNode {
        switch self {
        case .leaf:
            return self

        case .split(var split):
            if split.id == splitID {
                split.ratio = min(
                    Split.maximumRatio, max(Split.minimumRatio, ratio))
            } else {
                split.first = split.first.settingRatio(ratio, forSplit: splitID)
                split.second = split.second.settingRatio(ratio, forSplit: splitID)
            }
            return .split(split)
        }
    }

    /// Point a pane at a different terminal — used when the server answers a
    /// split with the id of the terminal it made.
    func setting(terminalID: UInt64, forPane paneID: UUID) -> SplitNode {
        switch self {
        case .leaf(var pane):
            guard pane.id == paneID else { return self }
            pane.terminalID = terminalID
            return .leaf(pane)

        case .split(var split):
            split.first = split.first.setting(terminalID: terminalID, forPane: paneID)
            split.second = split.second.setting(terminalID: terminalID, forPane: paneID)
            return .split(split)
        }
    }

    // MARK: - Navigation

    /// The pane in a given direction from `paneID`, for keyboard focus moves.
    ///
    /// Geometric rather than tree-order: within the nearest enclosing split
    /// that runs the right way, step to the neighbouring subtree and take the
    /// pane closest to the edge we came from.
    func pane(_ direction: FocusDirection, of paneID: UUID) -> Pane? {
        guard case .split(let split) = self else { return nil }

        // A deeper split may own the move; the outer one only gets it if
        // neither child does.
        if let inner = split.first.pane(direction, of: paneID) { return inner }
        if let inner = split.second.pane(direction, of: paneID) { return inner }

        guard split.direction == direction.axis else { return nil }
        if direction.isForward {
            guard split.first.panes.contains(where: { $0.id == paneID }) else { return nil }
            return split.second.panes.first
        }
        guard split.second.panes.contains(where: { $0.id == paneID }) else { return nil }
        return split.first.panes.last
    }

    enum FocusDirection {
        case left, right, up, down

        var axis: Direction {
            switch self {
            case .left, .right: .columns
            case .up, .down: .rows
            }
        }

        var isForward: Bool {
            switch self {
            case .right, .down: true
            case .left, .up: false
            }
        }
    }
}
