//  SplitTreeTests.swift
//  The layout model, with no view, window or terminal attached.

import IllogicalProtocol
import XCTest

final class SplitTreeTests: XCTestCase {
    /// Every pane in here is on one machine; which one is `TerminalRef`'s
    /// business, and the tree's behaviour does not depend on it.
    private static let host = ServerHost.local(socketPath: "/tmp/illogical-test.sock")
    private static func ref(_ id: UInt64) -> TerminalRef {
        TerminalRef(host: host, terminal: id)
    }
    private func pane(_ id: UInt64) -> Pane { Pane(terminal: Self.ref(id)) }
    private func leaf(_ id: UInt64) -> SplitNode { .leaf(pane(id)) }

    // MARK: - Splitting

    func testSplittingALeafMakesAPair() {
        let tree = leaf(1)
        let first = try! XCTUnwrap(tree.panes.first)
        let split = tree.splitting(first.id, with: pane(2), direction: .columns)

        XCTAssertEqual(split.panes.map(\.terminal.terminal), [1, 2])
        XCTAssertFalse(split.isLeaf)
    }

    /// The new pane goes second, which is what both icons draw: split right
    /// puts it on the right, split down puts it below.
    func testTheNewPaneGoesSecond() {
        var tree = leaf(1)
        let root = tree.panes[0]
        tree = tree.splitting(root.id, with: pane(2), direction: .columns)
        guard case .split(let split) = tree else { return XCTFail("not a split") }
        XCTAssertEqual(split.first.panes.map(\.terminal.terminal), [1])
        XCTAssertEqual(split.second.panes.map(\.terminal.terminal), [2])
    }

    func testSplittingADeepPane() {
        var tree = leaf(1)
        tree = tree.splitting(tree.panes[0].id, with: pane(2), direction: .columns)
        tree = tree.splitting(tree.panes[1].id, with: pane(3), direction: .rows)
        XCTAssertEqual(tree.panes.map(\.terminal.terminal), [1, 2, 3])
    }

    func testSplittingAnUnknownPaneChangesNothing() {
        let tree = leaf(1)
        XCTAssertEqual(tree.splitting(UUID(), with: pane(2), direction: .rows), tree)
    }

    // MARK: - Removing

    /// A split with one child left is not a split. Leaving the empty branch in
    /// place would give the survivor half the space and no way to get it back.
    func testRemovingCollapsesTheSplit() {
        var tree = leaf(1)
        tree = tree.splitting(tree.panes[0].id, with: pane(2), direction: .columns)
        let removed = try! XCTUnwrap(tree.removing(tree.panes[0].id))

        XCTAssertTrue(removed.isLeaf)
        XCTAssertEqual(removed.panes.map(\.terminal.terminal), [2])
    }

    func testRemovingTheLastPaneLeavesNothing() {
        let tree = leaf(1)
        XCTAssertNil(tree.removing(tree.panes[0].id))
    }

    func testRemovingFromANestedTree() {
        var tree = leaf(1)
        tree = tree.splitting(tree.panes[0].id, with: pane(2), direction: .columns)
        tree = tree.splitting(tree.panes[1].id, with: pane(3), direction: .rows)

        let removed = try! XCTUnwrap(tree.removing(tree.panes[1].id))
        XCTAssertEqual(removed.panes.map(\.terminal.terminal), [1, 3])
        // The inner split collapsed, so the outer one is a plain pair again.
        guard case .split(let split) = removed else { return XCTFail("not a split") }
        XCTAssertTrue(split.first.isLeaf)
        XCTAssertTrue(split.second.isLeaf)
    }

    // MARK: - Ratios

    /// A pane you cannot grab back is a pane you have lost, so the divider
    /// stops short of both edges.
    func testRatioIsClamped() {
        var tree = leaf(1)
        tree = tree.splitting(tree.panes[0].id, with: pane(2), direction: .columns)
        guard case .split(let split) = tree else { return XCTFail("not a split") }

        guard case .split(let wide) = tree.settingRatio(5, forSplit: split.id) else {
            return XCTFail("not a split")
        }
        XCTAssertEqual(wide.ratio, SplitNode.Split.maximumRatio)

        guard case .split(let narrow) = tree.settingRatio(-2, forSplit: split.id) else {
            return XCTFail("not a split")
        }
        XCTAssertEqual(narrow.ratio, SplitNode.Split.minimumRatio)
    }

    // MARK: - Focus navigation

    /// Two panes side by side: right from the left one, left from the right
    /// one, and nothing vertically.
    func testFocusAcrossAColumnSplit() {
        var tree = leaf(1)
        tree = tree.splitting(tree.panes[0].id, with: pane(2), direction: .columns)
        let left = tree.panes[0]
        let right = tree.panes[1]

        XCTAssertEqual(tree.pane(.right, of: left.id)?.id, right.id)
        XCTAssertEqual(tree.pane(.left, of: right.id)?.id, left.id)
        XCTAssertNil(tree.pane(.up, of: left.id))
        XCTAssertNil(tree.pane(.down, of: left.id))
        XCTAssertNil(tree.pane(.right, of: right.id))
    }

    /// The nearest enclosing split that runs the right way owns the move. In
    /// a column split whose right half is stacked, "down" from the top-right
    /// pane is the bottom-right one, not nothing.
    func testFocusPrefersTheInnerSplit() {
        var tree = leaf(1)
        tree = tree.splitting(tree.panes[0].id, with: pane(2), direction: .columns)
        tree = tree.splitting(tree.panes[1].id, with: pane(3), direction: .rows)

        let left = tree.panes[0]
        let topRight = tree.panes[1]
        let bottomRight = tree.panes[2]

        XCTAssertEqual(tree.pane(.down, of: topRight.id)?.id, bottomRight.id)
        XCTAssertEqual(tree.pane(.up, of: bottomRight.id)?.id, topRight.id)
        // Left from either right-hand pane is the single left pane.
        XCTAssertEqual(tree.pane(.left, of: topRight.id)?.id, left.id)
        XCTAssertEqual(tree.pane(.left, of: bottomRight.id)?.id, left.id)
        XCTAssertNil(tree.pane(.up, of: left.id))
    }

    // MARK: - Terminal ids

    func testPaneCanBePointedAtADifferentTerminal() {
        var tree = leaf(1)
        tree = tree.setting(terminal: Self.ref(7), forPane: tree.panes[0].id)
        XCTAssertEqual(tree.panes.map(\.terminal.terminal), [7])
        XCTAssertNotNil(tree.pane(forTerminal: Self.ref(7)))
        XCTAssertNil(tree.pane(forTerminal: Self.ref(1)))
    }

    // MARK: - Tabs

    func testRepairFocusAfterAPaneGoes() {
        var tab = TabLayout(
            session: SessionRef(host: Self.host, session: 1), terminal: Self.ref(1))
        let root = tab.panes[0]
        tab.root = tab.root.splitting(root.id, with: pane(2), direction: .columns)
        tab.focused = tab.panes[1].id
        tab.zoomed = tab.panes[1].id
        XCTAssertTrue(tab.isSplit)

        tab.root = try! XCTUnwrap(tab.root.removing(tab.panes[1].id))
        tab.repairFocus()

        XCTAssertEqual(tab.focused, root.id)
        XCTAssertNil(tab.zoomed)
        XCTAssertFalse(tab.isSplit)
    }
}
