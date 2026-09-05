//  SplitContainer.swift
//  A tab's tree, laid out with draggable dividers.
//
//  Ordinary views all the way down. There is no layout protocol and nothing
//  to negotiate with the server: each leaf is a `TerminalPane` holding its own
//  connection to its own PTY, and the tree is local state.

import SwiftUI

struct SplitContainer: View {
    @Environment(SessionStore.self) private var store
    let tab: TabLayout

    var body: some View {
        if let zoomed = tab.zoomed, let pane = tab.root.pane(zoomed) {
            // Zoom hides the tree rather than resizing it, so the panes behind
            // keep their grid size and nothing reflows on the way in or out.
            TerminalPane(pane: pane, tab: tab.id)
                .environment(store)
        } else {
            SplitNodeView(node: tab.root, tab: tab.id)
                .environment(store)
        }
    }
}

struct SplitNodeView: View {
    @Environment(SessionStore.self) private var store
    let node: SplitNode
    let tab: TabLayout.ID

    var body: some View {
        switch node {
        case .leaf(let pane):
            TerminalPane(pane: pane, tab: tab).environment(store)
        case .split(let split):
            SplitPair(split: split, tab: tab).environment(store)
        }
    }
}

/// Two subtrees and the divider between them.
struct SplitPair: View {
    @Environment(SessionStore.self) private var store
    let split: SplitNode.Split
    let tab: TabLayout.ID

    /// The ratio the current drag started from. A drag reports translation
    /// from where it began, so without this the divider would jump to the
    /// pointer on the first pixel of movement.
    @State private var dragOrigin: Double?

    static let dividerThickness: CGFloat = 1
    /// Grab area. One pixel of divider is impossible to hit; every split view
    /// on the platform widens the target without widening the line.
    static let grabThickness: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            let total =
                split.direction == .columns ? geometry.size.width : geometry.size.height
            let usable = max(0, total - Self.dividerThickness)
            let first = usable * split.ratio

            if split.direction == .columns {
                HStack(spacing: 0) {
                    SplitNodeView(node: split.first, tab: tab).environment(store)
                        .frame(width: first)
                    divider(total: total)
                    SplitNodeView(node: split.second, tab: tab).environment(store)
                        .frame(width: max(0, usable - first))
                }
            } else {
                VStack(spacing: 0) {
                    SplitNodeView(node: split.first, tab: tab).environment(store)
                        .frame(height: first)
                    divider(total: total)
                    SplitNodeView(node: split.second, tab: tab).environment(store)
                        .frame(height: max(0, usable - first))
                }
            }
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(
                width: split.direction == .columns ? Self.dividerThickness : nil,
                height: split.direction == .rows ? Self.dividerThickness : nil
            )
            .overlay {
                // The grab area is wider than the line and invisible.
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(
                        width: split.direction == .columns ? Self.grabThickness : nil,
                        height: split.direction == .rows ? Self.grabThickness : nil
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            split.direction == .columns
                                ? NSCursor.resizeLeftRight.push() : NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let origin = dragOrigin ?? split.ratio
                                dragOrigin = origin
                                let moved =
                                    split.direction == .columns
                                    ? value.translation.width : value.translation.height
                                let usable = max(1, total - Self.dividerThickness)
                                store.setRatio(
                                    origin + moved / usable, forSplit: split.id, in: tab)
                            }
                            .onEnded { _ in dragOrigin = nil })
            }
    }
}
