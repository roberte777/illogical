//  ScrollbarOverlay.swift
//  The scroll position indicator.
//
//  An overlay layer rather than a real NSScrollView. There is no document
//  view to scroll — the terminal's content is an IOSurface the renderer owns
//  and repaints in place — and the scrollable area changes shape underneath
//  us as output arrives and scrollback is pruned. A scroll view would need a
//  fictional document to manage; this just draws where we are.
//
//  Behaves like the system's overlay scrollbars: appears while you scroll,
//  fades out shortly after you stop.
//
//  Two marks, not one. The knob is where the viewport is; the pending track
//  above it is history the attach snapshot has declared and not yet
//  delivered. Drawing that region is what stops the bar from lying during an
//  attach — without it the scrollable area grows as pages land and the knob
//  slides down under a user who has not touched the wheel.

import AppKit
import QuartzCore

final class ScrollbarOverlay {
    /// The container. It spans the view, and the fade lives here so both
    /// marks appear and disappear together.
    let layer: CALayer

    /// Where the viewport is.
    private let knob: CALayer
    /// Declared but undelivered history, above the knob. Hidden once there is
    /// none, which for a terminal that is not mid-attach is always.
    private let pending: CALayer

    private static let width: CGFloat = 7
    private static let inset: CGFloat = 2
    private static let minimumKnobHeight: CGFloat = 24

    /// Where the knob sits. The layers stay private; their geometry is the
    /// part worth reading back, and all of this is arithmetic over the
    /// scrollable area rather than anything AppKit decides.
    var knobFrame: CGRect { knob.frame }

    /// Where the undelivered history sits, or nil when none is owed.
    var pendingFrame: CGRect? { pending.isHidden ? nil : pending.frame }

    init() {
        layer = CALayer()
        layer.opacity = 0
        // We drive the fade ourselves; an implicit animation on every
        // position change would smear the marks as they track the scroll.
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "sublayers": NSNull()]

        knob = CALayer()
        knob.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
        knob.cornerRadius = Self.width / 2
        knob.actions = ["position": NSNull(), "bounds": NSNull()]

        // Dim enough to read as "not yet" rather than as a second knob. It
        // sits in the track the knob travels, so at full strength the two
        // would be hard to tell apart at seven points wide.
        pending = CALayer()
        pending.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
        pending.cornerRadius = Self.width / 2
        pending.isHidden = true
        pending.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]

        layer.addSublayer(pending)
        layer.addSublayer(knob)
    }

    /// Place the marks for the given scrollable area.
    func update(_ state: TerminalEngine.ScrollbarState, in bounds: CGRect, scale: CGFloat) {
        // Nothing to place. Clear the pending mark rather than leaving the
        // last one standing: a terminal whose area has collapsed owes nothing.
        guard state.total > 0, bounds.height > 0 else {
            pending.isHidden = true
            return
        }

        let visible = Double(state.length) / Double(state.total)
        let position = Double(state.offset) / Double(state.total)

        let trackHeight = bounds.height - Self.inset * 2
        let knobHeight = max(Self.minimumKnobHeight, trackHeight * CGFloat(visible))
        // Position within the space the knob can actually occupy, so the ends
        // line up with the top and bottom of the track even when the knob has
        // been clamped to its minimum height.
        let travel = max(0, trackHeight - knobHeight)
        let y = Self.inset + travel * CGFloat(min(1, max(0, position / max(0.0001, 1 - visible))))

        layer.contentsScale = scale
        layer.frame = bounds
        // The container is positioned, so the marks are placed within it.
        let x = bounds.width - Self.width - Self.inset

        knob.contentsScale = scale
        knob.frame = CGRect(x: x, y: y, width: Self.width, height: knobHeight)

        // The pending region is a range of content, not a knob, so it maps
        // straight onto the track: rows 0..<pending of an area `total` tall.
        // Un-clamped, its far edge is exactly where the knob comes to rest
        // when scrolled to the oldest row that has arrived — the two meet,
        // and the bar reads as one continuous history with its top still
        // filling in.
        pending.isHidden = state.pending == 0
        guard state.pending > 0 else { return }
        let pendingHeight = trackHeight * CGFloat(Double(state.pending) / Double(state.total))
        pending.contentsScale = scale
        pending.frame = CGRect(
            x: x, y: Self.inset, width: Self.width, height: pendingHeight)
    }

    func show() {
        guard layer.opacity != 1 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = 1
        fade.duration = 0.08
        layer.opacity = 1
        layer.add(fade, forKey: "fade")
    }

    func hide() {
        guard layer.opacity != 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = 0
        fade.duration = 0.35
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
    }
}
