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

import AppKit
import QuartzCore

final class ScrollbarOverlay {
    let layer: CALayer

    private static let width: CGFloat = 7
    private static let inset: CGFloat = 2
    private static let minimumKnobHeight: CGFloat = 24

    init() {
        layer = CALayer()
        layer.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
        layer.cornerRadius = Self.width / 2
        layer.opacity = 0
        // We drive the fade ourselves; an implicit animation on every
        // position change would smear the knob as it tracks the scroll.
        layer.actions = ["position": NSNull(), "bounds": NSNull()]
    }

    /// Place the knob for the given scrollable area.
    func update(_ state: TerminalEngine.ScrollbarState, in bounds: CGRect, scale: CGFloat) {
        guard state.total > 0, bounds.height > 0 else { return }

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
        layer.frame = CGRect(
            x: bounds.width - Self.width - Self.inset,
            y: y,
            width: Self.width,
            height: knobHeight)
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
