//  SplitTree.swift
//  Client-side pane layout.
//
//  Splits live entirely here. The server never divides a grid and has no idea
//  this file exists: each leaf is one terminal, with its own connection to its
//  own PTY, exactly as if it were in a separate window. That is the whole point
//  of docs/ARCHITECTURE.md's "no in-band multiplexing" — the layout is native
//  view geometry, not characters drawn into somebody's terminal.

import IllogicalProtocol
import SwiftUI

indirect enum SplitTree: Equatable {
    case leaf(UInt64)
    case split(axis: Axis, first: SplitTree, second: SplitTree, fraction: Double)

    enum Axis: Equatable {
        /// Panes side by side.
        case horizontal
        /// Panes stacked.
        case vertical
    }

    /// Every terminal in the tree, left to right, top to bottom.
    var terminals: [UInt64] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, let first, let second, _): first.terminals + second.terminals
        }
    }

    func contains(_ id: UInt64) -> Bool { terminals.contains(id) }

    /// Split the pane holding `target`, putting `newTerminal` beside it.
    func splitting(_ target: UInt64, with newTerminal: UInt64, axis: Axis) -> SplitTree {
        switch self {
        case .leaf(let id):
            id == target
                ? .split(
                    axis: axis, first: .leaf(id), second: .leaf(newTerminal), fraction: 0.5)
                : self
        case .split(let axis0, let first, let second, let fraction):
            .split(
                axis: axis0,
                first: first.splitting(target, with: newTerminal, axis: axis),
                second: second.splitting(target, with: newTerminal, axis: axis),
                fraction: fraction)
        }
    }

    /// Remove a pane, collapsing the split that held it.
    func removing(_ target: UInt64) -> SplitTree? {
        switch self {
        case .leaf(let id):
            id == target ? nil : self
        case .split(let axis, let first, let second, let fraction):
            switch (first.removing(target), second.removing(target)) {
            case (nil, nil): nil
            case (let a?, nil): a
            case (nil, let b?): b
            case (let a?, let b?):
                .split(axis: axis, first: a, second: b, fraction: fraction)
            }
        }
    }
}

/// Renders a split tree. Each leaf gets its own `TerminalPane`, and therefore
/// its own connection.
struct SplitTreeView: View {
    @Environment(SessionStore.self) private var store
    let tree: SplitTree
    let terminals: [UInt64: TerminalSummary]

    var body: some View {
        switch tree {
        case .leaf(let id):
            if let terminal = terminals[id] {
                TerminalPane(terminal: terminal)
                    .environment(store)
                    .id(id)
                    .overlay(alignment: .topTrailing) {
                        if store.focusedTerminalID == id, store.layout.terminals.count > 1 {
                            // A hairline, not a glow: the focused pane should be
                            // identifiable without being loud.
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Palette.tabActiveStroke, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .onTapGesture { store.focusedTerminalID = id }
            } else {
                Color.clear
            }

        case .split(let axis, let first, let second, let fraction):
            GeometryReader { geo in
                let divider: CGFloat = 1
                switch axis {
                case .horizontal:
                    let width = (geo.size.width - divider) * fraction
                    HStack(spacing: 0) {
                        SplitTreeView(tree: first, terminals: terminals)
                            .environment(store)
                            .frame(width: width)
                        Rectangle().fill(Palette.divider).frame(width: divider)
                        SplitTreeView(tree: second, terminals: terminals)
                            .environment(store)
                    }
                case .vertical:
                    let height = (geo.size.height - divider) * fraction
                    VStack(spacing: 0) {
                        SplitTreeView(tree: first, terminals: terminals)
                            .environment(store)
                            .frame(height: height)
                        Rectangle().fill(Palette.divider).frame(height: divider)
                        SplitTreeView(tree: second, terminals: terminals)
                            .environment(store)
                    }
                }
            }
        }
    }
}
