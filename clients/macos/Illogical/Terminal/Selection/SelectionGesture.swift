//  SelectionGesture.swift
//  libghostty-vt's selection gesture state machine.
//
//  Selection looks like it should be twenty lines — anchor on mouse-down,
//  extend on drag — and it is not. Double-click selects a word and then drags
//  by *whole words*; triple-click does the same for lines; a drag that leaves
//  the top of the view has to autoscroll and keep extending; the anchor has to
//  survive every mutation the terminal makes while the button is held, which
//  for us is every frame of output. All of that is in `selection.h`, so none
//  of it is here.
//
//  What is here is the mapping from a pointer position to a grid reference and
//  the lifetime rules around it. Both are unforgiving:
//
//  A `GhosttyGridRef` is valid only until the next mutating call on the
//  terminal that produced it. Ours mutates on the reader thread whenever the
//  PTY says anything, so a ref may not outlive the lock. Every method here
//  therefore takes the terminal as an argument and stores nothing.
//
//  The gesture itself owns *tracked* references, which do survive mutation —
//  and which must be released against the terminal they came from, before it
//  is freed. That is why `TerminalEngine` owns this object and resets it in
//  `adopt`, rather than the view owning it and finding out later.

import Foundation
import GhosttyVt

/// Not thread-safe. Every method must be called under `TerminalEngine`'s lock,
/// with that engine's current terminal.
final class SelectionGesture: @unchecked Sendable {
    private var gesture: GhosttySelectionGesture?
    private var pressEvent: GhosttySelectionGestureEvent?
    private var dragEvent: GhosttySelectionGestureEvent?
    private var releaseEvent: GhosttySelectionGestureEvent?
    private var tickEvent: GhosttySelectionGestureEvent?

    init() {
        var gesture: GhosttySelectionGesture?
        guard ghostty_selection_gesture_new(nil, &gesture) == GHOSTTY_SUCCESS else { return }
        self.gesture = gesture

        pressEvent = Self.event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS)
        dragEvent = Self.event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG)
        releaseEvent = Self.event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE)
        tickEvent = Self.event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK)
    }

    private static func event(
        _ type: GhosttySelectionGestureEventType
    ) -> GhosttySelectionGestureEvent? {
        var event: GhosttySelectionGestureEvent?
        guard ghostty_selection_gesture_event_new(nil, &event, type) == GHOSTTY_SUCCESS else {
            return nil
        }
        return event
    }

    deinit {
        for event in [pressEvent, dragEvent, releaseEvent, tickEvent] {
            if let event { ghostty_selection_gesture_event_free(event) }
        }
        // The terminal is gone by the time anything frees us without calling
        // `free(terminal:)` first, and the header says to pass NULL then: its
        // page storage has already released the tracked references.
        if let gesture { ghostty_selection_gesture_free(gesture, nil) }
    }

    /// Release tracked references and drop the gesture, against the terminal
    /// they belong to.
    func free(terminal: GhosttyTerminal?) {
        guard let gesture else { return }
        ghostty_selection_gesture_free(gesture, terminal)
        self.gesture = nil
    }

    /// Cancel the click sequence and release tracked references.
    ///
    /// Must be called with the terminal the references belong to *before*
    /// that terminal is freed.
    func reset(terminal: GhosttyTerminal?) {
        guard let gesture else { return }
        ghostty_selection_gesture_reset(gesture, terminal)
    }

    // MARK: - Events

    /// Begin a click sequence. Returns the selection to install, or nil when
    /// this press produces none — a plain single click, which should clear
    /// whatever was selected before.
    func press(
        terminal: GhosttyTerminal,
        ref: GhosttyGridRef,
        position: GhosttySurfacePosition,
        timeNs: UInt64,
        repeatIntervalNs: UInt64,
        rectangle: Bool
    ) -> GhosttySelection? {
        guard let gesture, let event = pressEvent else { return nil }
        var ref = ref
        var position = position
        var timeNs = timeNs
        var repeatIntervalNs = repeatIntervalNs
        var rectangle = rectangle
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &timeNs)
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &repeatIntervalNs)
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle)
        return apply(gesture, terminal, event)
    }

    func drag(
        terminal: GhosttyTerminal,
        ref: GhosttyGridRef,
        position: GhosttySurfacePosition,
        geometry: GhosttySelectionGestureGeometry,
        rectangle: Bool
    ) -> GhosttySelection? {
        guard let gesture, let event = dragEvent else { return nil }
        var ref = ref
        var position = position
        var geometry = geometry
        var rectangle = rectangle
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle)
        return apply(gesture, terminal, event)
    }

    /// Extend the selection to a viewport row while the pointer sits outside
    /// the view and the viewport scrolls under it.
    func autoscrollTick(
        terminal: GhosttyTerminal,
        viewport: GhosttyPointCoordinate,
        geometry: GhosttySelectionGestureGeometry,
        rectangle: Bool
    ) -> GhosttySelection? {
        guard let gesture, let event = tickEvent else { return nil }
        var viewport = viewport
        var geometry = geometry
        var rectangle = rectangle
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &viewport)
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
        set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle)
        return apply(gesture, terminal, event)
    }

    /// End the click sequence. Produces no selection by design — the one from
    /// the last drag stands.
    func release(terminal: GhosttyTerminal, ref: GhosttyGridRef?) {
        guard let gesture, let event = releaseEvent else { return }
        if var ref {
            set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        } else {
            _ = ghostty_selection_gesture_event_set(
                event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil)
        }
        _ = ghostty_selection_gesture_event(gesture, terminal, event, nil)
    }

    // MARK: - State

    /// Which way a held drag wants the viewport to move, if either.
    func autoscroll(terminal: GhosttyTerminal) -> GhosttySelectionGestureAutoscroll {
        guard let gesture else { return GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE }
        var value = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
        _ = ghostty_selection_gesture_get(
            gesture, terminal, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &value)
        return value
    }

    /// Whether the current click sequence has moved. A press-and-release that
    /// never dragged is a click, not an empty selection.
    func hasDragged(terminal: GhosttyTerminal) -> Bool {
        guard let gesture else { return false }
        var value = false
        guard
            ghostty_selection_gesture_get(
                gesture, terminal, GHOSTTY_SELECTION_GESTURE_DATA_DRAGGED, &value)
                == GHOSTTY_SUCCESS
        else { return false }
        return value
    }

    // MARK: - Plumbing

    private func set(
        _ event: GhosttySelectionGestureEvent,
        _ option: GhosttySelectionGestureEventOption,
        _ value: UnsafeRawPointer
    ) {
        _ = ghostty_selection_gesture_event_set(event, option, value)
    }

    private func apply(
        _ gesture: GhosttySelectionGesture,
        _ terminal: GhosttyTerminal,
        _ event: GhosttySelectionGestureEvent
    ) -> GhosttySelection? {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard
            ghostty_selection_gesture_event(gesture, terminal, event, &selection)
                == GHOSTTY_SUCCESS
        else { return nil }
        return selection
    }
}
