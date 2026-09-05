//  RendererConfig.swift
//  The knobs libghostty exposes for rendering, with its defaults.
//
//  We have no config file yet, so these are constants. They live in one type
//  rather than scattered through the renderer so that wiring a config up
//  later is a matter of filling this in from it.

import Foundation

struct RendererConfig {
    /// WCAG 2.0 minimum contrast ratio to enforce between text and its
    /// background. 1 disables the correction, which is Ghostty's default:
    /// forcing contrast overrides what the program actually asked for.
    var minimumContrast: Float = 1.0

    /// Alpha for faint (SGR 2) text.
    var faintOpacity: Double = 0.5

    /// Alpha of the cursor when the surface is focused.
    var cursorOpacity: Double = 1.0

    /// Draw text with font smoothing, which thickens the stroke.
    var fontThicken: Bool = false
    /// 0...255, where 0 is the lightest thickening rather than none.
    var fontThickenStrength: UInt8 = 255

    /// Alpha for the whole surface background.
    var backgroundOpacity: Double = 1.0
    /// Apply `backgroundOpacity` to cells with their own background colour,
    /// not just the default background.
    var backgroundOpacityCells: Bool = false

    /// Padding around the grid, in points, before scaling.
    var windowPaddingX: Double = 2
    var windowPaddingY: Double = 2

    /// What fills the padding around the grid.
    enum PaddingColor {
        /// The default background colour.
        case background
        /// The colour of the nearest cell, unless the edge row looks like it
        /// would smear (see `rowNeverExtendBg`).
        case extend
        /// The colour of the nearest cell, always.
        case extendAlways
    }
    var paddingColor: PaddingColor = .background

    /// Explicit selection colours. Nil inverts: selection background becomes
    /// the foreground colour and vice versa, which reads correctly against
    /// any theme.
    var selectionBackground: (r: UInt8, g: UInt8, b: UInt8)? = nil
    var selectionForeground: (r: UInt8, g: UInt8, b: UInt8)? = nil

    /// Scroll speed. Precision deltas (trackpad) are pixels and pass through
    /// as-is; discrete deltas (wheel) are ticks and get multiplied by the cell
    /// height, so one tick is three rows. libghostty's defaults.
    var scrollMultiplierPrecision: Double = 1
    var scrollMultiplierDiscrete: Double = 3

    /// Jump to the live output when a key is pressed, but not when output
    /// arrives. Also libghostty's defaults: typing means you want to see what
    /// you are typing, whereas output scrolling out from under you while you
    /// are reading history is infuriating.
    var scrollToBottomOnKeystroke: Bool = true
    var scrollToBottomOnOutput: Bool = false

    /// How the cursor blinks, when the terminal asks it to.
    var cursorBlinkInterval: Double = 0.6

    /// Colour blending. See `AlphaBlending`.
    var blending: AlphaBlending = .native

    var faintAlpha: UInt8 {
        UInt8(max(0, min(255, (faintOpacity * 255).rounded())))
    }
}
