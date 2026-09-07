//  TabLayout.swift
//  One tab: a layout of panes, each its own connection to its own PTY.
//
//  A tab has an identity of its own rather than being named by a terminal.
//  That matters as soon as splits exist: a tab named by the terminal it
//  started as has nothing to be called once you close that pane and keep
//  working in the other one.

import Foundation

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
