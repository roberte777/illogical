//  RendererConfig.swift
//  The knobs libghostty exposes for rendering, with its defaults.
//
//  Defaults, and only defaults. What the config file says about any of them
//  is applied by `AppConfig.renderer`, which is the only thing that knows
//  both this vocabulary and the file's -- nothing under `Renderer/` imports
//  the config package. A knob the file has no key for is simply the constant
//  below, which is the state most of them are still in.

import Foundation

/// A colour that may instead be one the cell already has.
///
/// The renderer's half of `ConfigTerminalColor`: `cursor-color` and the two
/// selection colours can each be a fixed colour, or `cell-foreground` /
/// `cell-background`, which are resolved per cell against the character being
/// covered. That is the only way a cursor or a selection can invert what it
/// lands on rather than be one colour everywhere, and it is why these cannot
/// simply be resolved once and stored as RGB.
enum RenderColor: Equatable {
    case color(r: UInt8, g: UInt8, b: UInt8)
    case cellForeground
    case cellBackground

    /// Resolve against one cell.
    ///
    /// `foreground` and `background` are the cell's own colours, already
    /// fallen back to the terminal's defaults. `inverse` swaps which is which,
    /// exactly as libghostty's renderer does: on a cell drawn in reverse
    /// video, the colour you can see as its foreground is the one it stores as
    /// its background.
    func resolve(
        foreground: PackedRGB, background: PackedRGB, inverse: Bool
    ) -> PackedRGB {
        switch self {
        case .color(let r, let g, let b): return PackedRGB(r: r, g: g, b: b)
        case .cellForeground: return inverse ? background : foreground
        case .cellBackground: return inverse ? foreground : background
        }
    }
}

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
    ///
    /// 8 rather than libghostty's 2, and the one place in this file where the
    /// default is ours rather than its. The terminal is a card inset in the
    /// window now, and 2pt inside a rounded corner reads as text touching the
    /// edge — the reference leaves 11px, which on the 4:3 capture the rest of
    /// the chrome was measured from is 8pt.
    var windowPaddingX: Double = 8
    var windowPaddingY: Double = 8

    /// What to do with the space a grid of whole cells cannot fill.
    ///
    /// `.none`, which is libghostty's own default for `window-padding-balance`
    /// and the only value that holds still: the top-left cell hugs the corner
    /// and the slack — up to a cell in each axis — sits at the right and the
    /// bottom, where nothing is drawn. Balancing splits that slack between the
    /// opposite edges instead, which means the grid's origin is a function of
    /// the surface size: drag a window edge and every row on screen slides by
    /// half a cell and snaps back on each row the grid gains, which reads as
    /// the text jittering under the pointer.
    var windowPaddingBalance: PaddingBalance = .none

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

    /// Explicit selection colours. Nil inverts against the *terminal*:
    /// selection background becomes the default foreground colour and vice
    /// versa, which reads correctly against any theme.
    ///
    /// `cell-foreground` and `cell-background` invert against the *cell*
    /// instead, which is a different picture — a selection over syntax
    /// highlighting keeps each token's own colour rather than flattening the
    /// lot to two. Themes set this pair often; most set fixed colours.
    var selectionBackground: RenderColor? = nil
    var selectionForeground: RenderColor? = nil

    /// The cursor, and the character under it.
    ///
    /// Only the `cell-` cases ever reach here as a cursor colour: a fixed
    /// `cursor-color` is set on the terminal instead, so that a program's
    /// OSC 12 can override it and `OSC 112` can put it back. Nil for the
    /// cursor means the terminal's foreground; nil for the text under it
    /// means the terminal's background, which is what makes a block cursor
    /// read as a knockout.
    var cursorColor: RenderColor? = nil
    var cursorText: RenderColor? = nil

    /// Search match colours, and the match the find bar is on.
    ///
    /// Not optional, unlike the selection's: inverting is already what a
    /// selection looks like, so a search that inverted too would be
    /// indistinguishable from one — and the whole point of the second pair is
    /// that you can see *which* of a screenful of hits you are standing on.
    /// The selected pair is sampled from the reference recording, where the
    /// match you are on is a saturated yellow with near-black text. The other
    /// pair is that yellow taken down to a dim olive with light text, which is
    /// what a match you are *not* on looks like there and what every
    /// terminal's find has looked like since less(1).
    var searchBackground: (r: UInt8, g: UInt8, b: UInt8) = (0x5E, 0x55, 0x14)
    var searchForeground: (r: UInt8, g: UInt8, b: UInt8) = (0xF0, 0xEC, 0xD6)
    var searchSelectedBackground: (r: UInt8, g: UInt8, b: UInt8) = (0xD8, 0xC8, 0x19)
    var searchSelectedForeground: (r: UInt8, g: UInt8, b: UInt8) = (0x0C, 0x1F, 0x2F)

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
