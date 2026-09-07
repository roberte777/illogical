//  Motion.swift
//  The app's motion vocabulary, in one place.
//
//  Before this file the app had no animation at all: menus, tabs, splits and
//  banners appeared and vanished between two frames. The rule the chrome now
//  follows is narrow on purpose —
//
//    * Chrome animates. Terminals do not. Switching from one tab to another is
//      the thing this app does most often and it has to feel like nothing
//      happened, so the only motion on a tab switch is the active pill sliding
//      between two slots; the surface underneath swaps instantly.
//    * A divider drag is not motion. It tracks the pointer, so `setRatio` is
//      never wrapped in an animation — only the split tree's *topology*
//      changes are (a pane appearing, closing, zooming).
//    * Nothing here runs before the first frame. Every animation is attached to
//      a state change that can only happen after the window is on screen, which
//      is what keeps `just bench-launch` where it was.
//
//  Durations live here rather than at the call sites so the app has one
//  vocabulary instead of eleven magic numbers, and so the reduce-motion gate is
//  two pure functions — `animation(reduceMotion:)` and `entrance(reduceMotion:)`
//  — that every animated surface has to go through, rather than a rule each
//  view is trusted to remember.

import AppKit
import SwiftUI

/// One entry in the vocabulary: a duration, a curve, and what a view does on
/// the way in and out.
struct Motion: Equatable, Sendable {
    /// How a surface arrives and leaves.
    enum Entrance: Equatable, Sendable {
        case fade
        /// Grows from an anchor, the way an NSMenu does.
        case menu
        /// Slides in from the top edge.
        case fromTop

        /// The transition this entrance builds.
        ///
        /// Total, with no accessibility question in it — deliberately.
        /// `AnyTransition` is opaque: not `Equatable`, and it does not describe
        /// itself, so a reduce-motion check *here* would be a line no test
        /// could hold. An earlier draft of this file had exactly that, and
        /// deleting the check left all 314 tests green. The gate lives in
        /// `Motion.entrance(reduceMotion:)` instead, which returns a value, and
        /// since the stored entrance is private that function is the only way
        /// to reach this property at all.
        var transition: AnyTransition {
            switch self {
            case .fade:
                return .opacity
            case .menu:
                return .opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading))
            case .fromTop:
                return .move(edge: .top).combined(with: .opacity)
            }
        }
    }

    enum Curve: Equatable, Sendable {
        case easeOut
        case easeInOut
        /// SwiftUI's spring, with the overshoot taken out. What a tab strip
        /// wants: it settles rather than decelerating to a stop.
        case snappy
    }

    let duration: Double
    let curve: Curve

    /// What this surface does when the system is not asking for stillness.
    ///
    /// Private, and that is the whole design: `entrance(reduceMotion:)` is the
    /// only way out of this type to an `Entrance`, and `Entrance.transition` is
    /// the only way from there to an `AnyTransition`. A caller cannot reach a
    /// transition without passing the gate, because there is no expression that
    /// spells one.
    private let unreduced: Entrance

    init(duration: Double, curve: Curve, entrance: Entrance) {
        self.duration = duration
        self.curve = curve
        self.unreduced = entrance
    }

    /// The animation to attach, or nil when the system asks for no motion.
    ///
    /// Half of the accessibility guarantee — the other half is
    /// `entrance(reduceMotion:)`. Both are pure and both are pinned by
    /// `TabOrderTests`, which is the point of them being functions of a `Bool`
    /// rather than reads of `NSWorkspace`. `nil` is not a shorter animation: it
    /// is SwiftUI's "apply this change now".
    func animation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        switch curve {
        case .easeOut: return .easeOut(duration: duration)
        case .easeInOut: return .easeInOut(duration: duration)
        case .snappy: return .snappy(duration: duration)
        }
    }

    /// What this surface actually does, once the accessibility setting has had
    /// its say. Under Reduce Motion everything is a crossfade: opacity is the
    /// one change that does not move anything.
    func entrance(reduceMotion: Bool) -> Entrance {
        reduceMotion ? .fade : unreduced
    }

    /// The transition to attach, gated. Sugar for
    /// `entrance(reduceMotion:).transition` — it saves nothing but the reading,
    /// and it cannot be written without the gate.
    func transition(reduceMotion: Bool) -> AnyTransition {
        entrance(reduceMotion: reduceMotion).transition
    }
}

extension Motion {
    /// The session dropdown. Short and small: it is a menu, and a menu that
    /// takes longer than a menu reads as slow.
    static let menu = Motion(duration: 0.12, curve: .easeOut, entrance: .menu)

    /// The tab strip: slots arriving and leaving, and the active pill sliding
    /// between them.
    static let tabs = Motion(duration: 0.18, curve: .snappy, entrance: .fade)

    /// A pane appearing, closing or zooming. Frames animate because
    /// `SplitPair`'s geometry is a pure function of ratio and topology.
    static let splits = Motion(duration: 0.16, curve: .easeOut, entrance: .fade)

    /// The reconnect pill over a terminal.
    static let banner = Motion(duration: 0.2, curve: .easeOut, entrance: .fromTop)

    /// Swapping the whole content area between terminals, "no terminals" and
    /// "no server". Not tab-to-tab: that stays instant.
    static let screen = Motion(duration: 0.15, curve: .easeInOut, entrance: .fade)

    /// The residency marker on a tab's badge, so parked does not pop.
    static let badge = Motion(duration: 0.12, curve: .easeOut, entrance: .fade)
}

extension Motion {
    /// What the system asks for, for code with no SwiftUI environment to read
    /// it from.
    ///
    /// `SessionStore` mutates the split tree, and a `withAnimation` around that
    /// mutation is the only way a topology change animates at all — the tree is
    /// not a value any single view can key an `.animation(_:value:)` on. So the
    /// store reads the accessibility setting the way AppKit exposes it, which
    /// is the same setting `\.accessibilityReduceMotion` is derived from.
    @MainActor
    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Apply `body`'s changes inside this motion, honouring Reduce Motion.
    ///
    /// For the store. A view should use `animation(reduceMotion:)` with the
    /// environment value instead: it is scoped to one value changing, where
    /// this covers everything the closure touches.
    ///
    /// `reduceMotion` is a parameter rather than a read inside the body so that
    /// what is left untested here is as small as it can be made. `withAnimation`
    /// is not observable after the fact — there is no public way to read the
    /// ambient transaction outside a view update — so the *choice* of animation
    /// is pinned by `animation(reduceMotion:)`'s own tests, and this function is
    /// reduced to one expression over it. What the tests can and do hold about
    /// this function is that it runs the body exactly once and returns its
    /// value, under either flag.
    @MainActor
    func run<Result>(
        reduceMotion: Bool = Motion.systemReduceMotion, _ body: () throws -> Result
    ) rethrows -> Result {
        try withAnimation(animation(reduceMotion: reduceMotion), body)
    }
}
