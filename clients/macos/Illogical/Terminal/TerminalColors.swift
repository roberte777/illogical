//  TerminalColors.swift
//  The config's colours, in the terminal's own terms.
//
//  Four values go *into* libghostty rather than into the renderer — the
//  default background, foreground and cursor, and the 256-colour palette —
//  and that is not an implementation detail: the terminal owns them because a
//  program can change them out from under us. OSC 10, 11, 12 and 4 each
//  override one, `OSC 104`/`110`-`112` put it back, and the value they go back
//  *to* is the one set here. Resolving the palette in the renderer instead
//  would make `printf '\e]4;1;#ff0000\a'` a no-op.
//
//  This is also where the parts of a theme that this app cannot compute meet
//  the ones it can. `IllogicalConfig` is pure Swift and deliberately knows
//  neither libghostty's default palette nor how Ghostty derives a 256-colour
//  cube from sixteen base colours; both are C calls, and calling them is
//  exactly how `palette-generate` produces the same numbers Ghostty does
//  rather than a plausible imitation.

import GhosttyVt
import IllogicalConfig

/// What a terminal is told its colours are, before any program says otherwise.
struct TerminalColors {
    var background: GhosttyColorRgb
    var foreground: GhosttyColorRgb

    /// Nil when the config named no fixed cursor colour — either because it
    /// named none at all, or because it named `cell-foreground` /
    /// `cell-background`, which is not a colour the terminal could hold. The
    /// renderer resolves those per frame against the cell the cursor is on.
    ///
    /// Nil leaves the terminal's cursor colour unset, which is what makes
    /// `snapshot.cursorColor` mean "a program sent OSC 12" and nothing else.
    var cursor: GhosttyColorRgb?

    /// Exactly 256 entries.
    var palette: [GhosttyColorRgb]

    /// Resolve `config`, filling in from libghostty everything it does not say.
    static func from(_ config: Config) -> TerminalColors {
        TerminalColors(
            background: config.background.ghostty,
            foreground: config.foreground.ghostty,
            cursor: {
                guard case .color(let color) = config.cursorColor else { return nil }
                return color.ghostty
            }(),
            palette: palette(for: config))
    }

    /// The 256-colour palette: libghostty's default, the config's overrides on
    /// top, and the generated cube over that when it was asked for.
    ///
    /// The order is libghostty's own (`termio/Termio.zig`), and the last step
    /// is skipped entirely when nothing was overridden — with no base colours
    /// to derive from, generating would only reproduce the default palette at
    /// the cost of a round of CIELAB interpolation on every launch.
    private static func palette(for config: Config) -> [GhosttyColorRgb] {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        palette.withUnsafeMutableBufferPointer { ghostty_color_palette_default($0.baseAddress) }

        for (index, color) in config.palette.overrides {
            palette[Int(index)] = color.ghostty
        }
        guard config.paletteGenerate, !config.palette.isEmpty else { return palette }

        // The mask says which indices the generator must leave alone. Indices
        // 0–15 are preserved whatever it holds; what this adds is any index
        // *above* 15 that the config named, so that `palette = 200=#ff0000`
        // survives a generated cube that would otherwise cover it.
        var skip = GhosttyColorPaletteMask()
        withUnsafeMutableBytes(of: &skip.bits) { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for index in config.palette.overrides.keys {
                words[Int(index) >> 6] |= UInt64(1) << (UInt64(index) & 63)
            }
        }

        var background = config.background.ghostty
        var foreground = config.foreground.ghostty
        palette.withUnsafeMutableBufferPointer { buffer in
            ghostty_color_palette_generate(
                buffer.baseAddress, &skip, &background, &foreground,
                config.paletteHarmonious, buffer.baseAddress)
        }
        return palette
    }
}

extension ConfigColor {
    /// The same three bytes, under libghostty's name for them.
    var ghostty: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }
}
