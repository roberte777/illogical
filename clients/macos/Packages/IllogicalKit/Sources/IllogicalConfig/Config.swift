//  Config.swift
//  What the config file can say, and what saying it does.
//
//  Ghostty's format and Ghostty's option names, deliberately. The audience for
//  this app is largely the audience for that one, the two files will sit next
//  to each other on the same machine holding the same font, and a file that
//  *looks* identical while behaving differently is worse than one that looks
//  nothing alike. So the semantics are copied along with the syntax:
//  `font-family` repeats to build a fallback list rather than overwriting,
//  `key =` with nothing after it resets rather than sets empty, and an
//  unnamed style is looked for inside the family you did name rather than in
//  the next family down.
//
//  Only the font is here (#39 has the rest: scrollback cap, park threshold,
//  colours, keybindings). Nothing about the shape below is font-specific —
//  another option is a field, a case in `apply`, and a line in the template.

import Foundation

/// Everything the config file sets, after every file has been read.
///
/// Values only. Where they came from and what was wrong with them is
/// `ConfigLoad`'s, so that two configs holding the same font compare equal no
/// matter which file each was read from — which is what a reload has to ask.
public struct Config: Equatable, Sendable {
    public init() {}

    // MARK: - Font

    /// The families to draw the regular style from, in priority order. The
    /// first that has the codepoint wins; the system's own cascade is asked
    /// only once every one of them has missed.
    ///
    /// Empty means the font the app ships, which is the case for anyone who
    /// has not written a config file.
    ///
    /// A list rather than one name because that is what `font-family`
    /// repeating *means* — each line adds the next fallback:
    ///
    ///     font-family = Berkeley Mono
    ///     font-family = Noto Sans CJK
    ///
    /// which is how a person covers a language their programming font has no
    /// glyphs for. Since every line appends, clearing needs its own spelling:
    /// `font-family = ""` empties the list, and lines after it start a new
    /// one.
    public var fontFamily: [String] = []

    /// The same, for each style the terminal can ask for.
    ///
    /// Unset means "look inside `fontFamily`", not "fall to the next family":
    /// `finalize()` copies the regular list into whichever of these is empty,
    /// so a style is always searched for in the family the person actually
    /// named. libghostty is explicit that this is deliberate, and it is the
    /// one part of the font config that is easy to get subtly wrong — bold
    /// text quietly drawn from a different typeface than the text around it.
    public var fontFamilyBold: [String] = []
    public var fontFamilyItalic: [String] = []
    public var fontFamilyBoldItalic: [String] = []

    /// Font size in points. Fractional sizes are allowed: the grid is measured
    /// in pixels, so 13.5pt on a 2x display is a real 27px cell rather than a
    /// rounding of 26 or 28.
    ///
    /// 13 rather than 12 on macOS, which is libghostty's default and its
    /// stated reason — "this tends to look better" — and also what the app
    /// already drew before there was a config file.
    public var fontSize: Double = 13

    // MARK: - Window

    /// Alpha for the terminal's background, 0 through 1.
    ///
    /// The *terminal's*, and nothing else's: the toolbar, the tab strip and
    /// the breadcrumb stay opaque whatever this says. That is what keeps a
    /// translucent window usable -- chrome you can see through is chrome you
    /// cannot find -- and it is where libghostty draws the line too.
    ///
    /// 1 by default, which is also libghostty's default. Nobody gets a
    /// see-through terminal without asking for one.
    public var backgroundOpacity: Double = 1

    /// How hard to blur whatever shows through a translucent terminal, in
    /// pixels. 0 is no blur.
    ///
    /// Does nothing on its own. With `background-opacity = 1` there is
    /// nothing behind the terminal to blur, so this alone is a line that
    /// quietly has no effect; the two go together.
    ///
    /// Written as a bool *or* a radius, which is libghostty's own spelling:
    /// `background-blur = true` is 20, the radius it picks for the same word,
    /// and `background-blur = 30` is 30. Both are honoured -- see
    /// `WindowChrome`, which sets exactly this radius through the same
    /// private call Ghostty uses.
    public var backgroundBlurRadius: Int = 0

    // MARK: - Theme

    /// The theme file to read colours from, under the terminal's own two.
    ///
    /// Nil for no theme, which is the default and what leaves the app looking
    /// like itself. One name, or a light/dark pair — see `ConfigTheme`.
    ///
    /// Loading it is `ConfigLoad`'s job rather than this type's, and it has to
    /// be: a theme is a *file*, and the whole point of the option is that
    /// anything the config says explicitly outranks it however the two are
    /// ordered in the file. That is not something applying one entry at a time
    /// can do — see `Config.load(files:)`.
    public var theme: ConfigTheme?

    // MARK: - Colours

    /// The terminal's default background and foreground: what a cell that
    /// carries no colour of its own is drawn in.
    ///
    /// Not libghostty's defaults, and this is the one place the two files
    /// deliberately disagree. Ghostty defaults to `#282C34` under white; the
    /// app draws the dark blue it has drawn since before there was a config
    /// file, so that installing it does not silently repaint a terminal to
    /// look like a different program's. Every *theme* is Ghostty's, which is
    /// the part that matters — these two are only what you get having named
    /// no theme at all.
    public var background = ConfigColor(0x0C_1F_2F)
    public var foreground = ConfigColor(0xC8_D6_E0)

    /// The cursor's block, and the text under it. Nil leaves both to the
    /// renderer: the foreground for the block, the background for the text
    /// beneath it.
    ///
    /// `ConfigTerminalColor` rather than a plain colour because a theme may
    /// say `cell-foreground` or `cell-background` instead of naming one — a
    /// cursor that inverts whatever character it is standing on rather than
    /// being one fixed colour. That pair is also all `cursor-invert-fg-bg`
    /// ever meant, and it is applied as exactly that.
    public var cursorColor: ConfigTerminalColor?
    public var cursorText: ConfigTerminalColor?

    /// The selection's two colours, with the same three spellings.
    ///
    /// Nil for both inverts: selected text is drawn in the background colour
    /// on the foreground colour, which reads correctly under any theme and is
    /// what the app did before it could be told otherwise.
    public var selectionBackground: ConfigTerminalColor?
    public var selectionForeground: ConfigTerminalColor?

    /// The `palette = N=COLOR` overrides. Whatever is not overridden is
    /// libghostty's own default palette — see `ConfigPalette`.
    public var palette = ConfigPalette()

    /// Derive indices 16–255 from the base sixteen rather than using the
    /// xterm cube and ramp, so that a theme naming only the first sixteen
    /// colours gets a whole palette in keeping with them.
    ///
    /// Off, which is libghostty's default and for its stated reason: a great
    /// deal of software hardcodes what the xterm cube's indices are, and
    /// moving them out from under it makes that software unreadable rather
    /// than merely differently coloured.
    public var paletteGenerate = false

    /// Run the generated cube light-to-dark under a light theme instead of
    /// keeping it dark-to-light. No effect unless `palette-generate` is on.
    public var paletteHarmonious = false

    /// Whether the window's controls -- the traffic lights, the buttons on a
    /// placeholder screen, a sheet -- draw light or dark.
    ///
    /// The chrome we paint ourselves follows the theme whatever this says;
    /// what this decides is the `NSAppearance` AppKit hands to everything we
    /// do *not* paint. A cream terminal in a window macOS still thinks is dark
    /// gets white-on-white system buttons, which is the one part of a light
    /// theme that cannot be fixed by choosing better colours.
    ///
    /// `auto` reads the theme's own background, which is libghostty's default
    /// and its rule: light above a perceived luminance of 0.5. Except with a
    /// light/dark theme *pair*, where `auto` would fight the pair -- the
    /// appearance is what chose the theme in the first place -- so it defers
    /// to `system`, exactly as libghostty does.
    public var windowTheme: ConfigWindowTheme = .auto

    /// The WCAG contrast ratio to force between a cell's text and its own
    /// background, 1 through 21. 1 is off.
    ///
    /// Off by default, which is libghostty's default and the right one: this
    /// overrides the colour a program actually asked for, and a program that
    /// asked for grey on grey usually meant it.
    public var minimumContrast: Double = 1

    // MARK: - Applying a file

    /// Apply every `key = value` in `text`, appending diagnostics for
    /// anything wrong.
    ///
    /// Public because it is the useful unit to test and the useful unit to
    /// reuse: a config that came from somewhere other than a file — a future
    /// `--config-string`, a settings UI writing a preview — goes through
    /// exactly this. `path` is only ever printed.
    public mutating func apply(
        text: String,
        path: String? = nil,
        diagnostics: inout [ConfigDiagnostic]
    ) {
        for entry in ConfigSyntax.entries(of: text) {
            apply(entry, path: path, diagnostics: &diagnostics)
        }
    }

    /// Apply one entry.
    ///
    /// Every key lands in the switch below, and an unknown one is reported
    /// rather than ignored. That has a cost worth naming: a person pasting
    /// their Ghostty config in gets a warning per option we do not have yet.
    /// Reporting is still right — the alternative is a typo'd `font-famly`
    /// that silently does nothing, which is the single most common way a
    /// config file wastes somebody's afternoon.
    public mutating func apply(
        _ entry: ConfigEntry,
        path: String? = nil,
        diagnostics: inout [ConfigDiagnostic]
    ) {
        func report(_ message: String) {
            diagnostics.append(
                ConfigDiagnostic(file: path, line: entry.line, key: entry.key, message: message))
        }

        // The list-valued keys, from the one table that also decides what
        // the command line resets. See `listValuedKeys`.
        if let keyPath = Self.listValuedKeys[entry.key] {
            apply(entry, to: keyPath, report: report)
            return
        }

        switch entry.key {
        case "font-size":
            guard let value = entry.value else {
                report("value required")
                return
            }
            if value.isEmpty {
                fontSize = Config().fontSize
                return
            }
            // `Double(_:)` and not a `NumberFormatter`: this is a config file,
            // not a locale-aware input, and `font-size = 13,5` should be
            // rejected rather than read as 135 in a French locale.
            guard let size = Double(value), size.isFinite, size > 0 else {
                // libghostty accepts a zero or negative size here and lets the
                // font stack deal with it. We do not, because our grid divides
                // by the cell the size produces: the failure would be a window
                // that draws nothing, a long way from the line that caused it.
                report("invalid value \"\(value)\"")
                return
            }
            fontSize = size

        case "background-opacity":
            guard let value = entry.value else {
                report("value required")
                return
            }
            if value.isEmpty {
                backgroundOpacity = Config().backgroundOpacity
                return
            }
            guard let alpha = Double(value), alpha.isFinite else {
                report("invalid value \"\(value)\"")
                return
            }
            // Clamped rather than rejected, which is what libghostty does
            // with the same value. `0.5` and `50` are both attempts to say
            // half, and only one of them is a mistake worth stopping for.
            backgroundOpacity = min(1, max(0, alpha))

        case "background-blur", "background-blur-radius":
            guard let value = entry.value else {
                report("value required")
                return
            }
            if value.isEmpty {
                backgroundBlurRadius = Config().backgroundBlurRadius
                return
            }
            guard let radius = ConfigSyntax.blurRadius(value) else {
                report("invalid value \"\(value)\"")
                return
            }
            backgroundBlurRadius = radius

        case "theme":
            guard let value = entry.value, !value.isEmpty else {
                // Empty is an error rather than a reset, which is
                // libghostty's call and worth keeping: every other key resets
                // to a default, and this one has no default to reset *to* —
                // `theme =` would have to mean "the colours a theme already
                // set", which is not a thing a config file can express.
                report("value required")
                return
            }
            guard let parsed = ConfigTheme.parse(value) else {
                report("invalid value \"\(value)\"")
                return
            }
            theme = parsed

        case "background":
            apply(entry, to: \.background, report: report)
        case "foreground":
            apply(entry, to: \.foreground, report: report)

        case "cursor-color":
            apply(entry, to: \.cursorColor, report: report)
        case "cursor-text":
            apply(entry, to: \.cursorText, report: report)
        case "selection-background":
            apply(entry, to: \.selectionBackground, report: report)
        case "selection-foreground":
            apply(entry, to: \.selectionForeground, report: report)

        case "palette":
            guard let value = entry.value else {
                report("value required")
                return
            }
            if value.isEmpty {
                palette.removeAll()
                return
            }
            guard let override = ConfigPalette.parseEntry(value) else {
                report("invalid value \"\(value)\"")
                return
            }
            palette.set(override.index, to: override.color)

        case "palette-generate":
            apply(entry, to: \.paletteGenerate, report: report)
        case "palette-harmonious":
            apply(entry, to: \.paletteHarmonious, report: report)

        case "window-theme":
            guard let value = entry.value else {
                report("value required")
                return
            }
            if value.isEmpty {
                windowTheme = Config().windowTheme
                return
            }
            guard let parsed = ConfigWindowTheme(rawValue: value) else {
                report("invalid value \"\(value)\"")
                return
            }
            windowTheme = parsed

        case "minimum-contrast":
            guard let value = entry.value else {
                report("value required")
                return
            }
            if value.isEmpty {
                minimumContrast = Config().minimumContrast
                return
            }
            guard let ratio = Double(value), ratio.isFinite else {
                report("invalid value \"\(value)\"")
                return
            }
            // 1 through 21 is the whole range a WCAG ratio has — 1 is a colour
            // against itself and 21 is black against white — so anything
            // outside it is a number somebody guessed at rather than measured.
            // Clamped rather than refused, for the same reason
            // `background-opacity` is.
            minimumContrast = min(21, max(1, ratio))

        // Ghostty 1.2 replaced these two with the `cell-foreground` and
        // `cell-background` values above, and still accepts them. So do we,
        // and by setting exactly what it sets: a config carried over from an
        // older Ghostty should keep working rather than warn about a key that
        // was correct when it was written.
        case "cursor-invert-fg-bg":
            guard let on = compatFlag(entry, report: report) else { return }
            if on {
                cursorColor = .cellForeground
                cursorText = .cellBackground
            }
        case "selection-invert-fg-bg":
            guard let on = compatFlag(entry, report: report) else { return }
            if on {
                selectionForeground = .cellBackground
                selectionBackground = .cellForeground
            }

        default:
            report("unknown field")
        }
    }

    /// A colour that must always have a value: an empty one resets it.
    private mutating func apply(
        _ entry: ConfigEntry,
        to keyPath: WritableKeyPath<Config, ConfigColor>,
        report: (String) -> Void
    ) {
        guard let value = entry.value else {
            report("value required")
            return
        }
        if value.isEmpty {
            self[keyPath: keyPath] = Config()[keyPath: keyPath]
            return
        }
        guard let color = ConfigColor.parse(value) else {
            report("invalid value \"\(value)\"")
            return
        }
        self[keyPath: keyPath] = color
    }

    /// A colour that may be unset, where empty means "unset" rather than "the
    /// default colour" — because for these four there is no default colour,
    /// only a rule the renderer follows in their absence.
    private mutating func apply(
        _ entry: ConfigEntry,
        to keyPath: WritableKeyPath<Config, ConfigTerminalColor?>,
        report: (String) -> Void
    ) {
        guard let value = entry.value else {
            report("value required")
            return
        }
        if value.isEmpty {
            self[keyPath: keyPath] = nil
            return
        }
        guard let color = ConfigTerminalColor.parse(value) else {
            report("invalid value \"\(value)\"")
            return
        }
        self[keyPath: keyPath] = color
    }

    /// A flag, in libghostty's spelling of one.
    private mutating func apply(
        _ entry: ConfigEntry,
        to keyPath: WritableKeyPath<Config, Bool>,
        report: (String) -> Void
    ) {
        guard let value = entry.value else {
            report("value required")
            return
        }
        if value.isEmpty {
            self[keyPath: keyPath] = Config()[keyPath: keyPath]
            return
        }
        guard let flag = ConfigSyntax.bool(value) else {
            report("invalid value \"\(value)\"")
            return
        }
        self[keyPath: keyPath] = flag
    }

    /// The flag half of a compatibility key, which differs from a real one in
    /// two ways: a bare key means true rather than "value required", and
    /// false does nothing at all rather than restoring a default. Both are
    /// libghostty's behaviour, and both follow from the key not having a
    /// field of its own to hold — there is nothing for `false` to undo.
    private func compatFlag(_ entry: ConfigEntry, report: (String) -> Void) -> Bool? {
        let value = entry.value ?? "t"
        guard let flag = ConfigSyntax.bool(value.isEmpty ? "t" : value) else {
            report("invalid value \"\(value)\"")
            return nil
        }
        return flag
    }

    /// The repeatable-string rule, which is the same for all four families.
    ///
    /// No `=` at all is an error rather than a reset. The difference matters:
    /// a bare `font-family` is a line someone stopped typing halfway, and
    /// resetting the list from it would be a silent surprise.
    private mutating func apply(
        _ entry: ConfigEntry,
        to keyPath: WritableKeyPath<Config, [String]>,
        report: (String) -> Void
    ) {
        guard let value = entry.value else {
            report("value required")
            return
        }
        if value.isEmpty {
            self[keyPath: keyPath].removeAll()
            return
        }
        self[keyPath: keyPath].append(value)
    }

    /// Settle the values that depend on each other. Run once, after the last
    /// file.
    ///
    /// One rule so far, and it is libghostty's: a named `font-family` with no
    /// style named alongside it fills in all three styles, so that
    /// `font-family = Berkeley Mono` looks for Berkeley Mono's own bold and
    /// italic rather than reaching for another family's.
    public mutating func finalize() {
        guard !fontFamily.isEmpty else { return }
        if fontFamilyBold.isEmpty { fontFamilyBold = fontFamily }
        if fontFamilyItalic.isEmpty { fontFamilyItalic = fontFamily }
        if fontFamilyBoldItalic.isEmpty { fontFamilyBoldItalic = fontFamily }
    }

    /// The keys whose entries append to a list rather than setting a value,
    /// and where each one's values go.
    ///
    /// A table rather than a set, and `apply` routes through it rather than
    /// listing the same four keys in its switch. That is deliberate: as two
    /// lists they could drift, and the direction that drifts silently is a
    /// new list-valued key added to the switch and forgotten here — the
    /// command line would then append to it instead of replacing, which is
    /// the whole bug this exists to prevent, and no test could see it. Routed
    /// through one table, there is nothing to keep in sync.
    /// Computed rather than stored: a key path is not `Sendable`, so the
    /// same table as a `static let` is a mutable global the compiler is
    /// right to complain about. Four entries built on demand, on a path
    /// that runs once per config line.
    public static var listValuedKeys: [String: WritableKeyPath<Config, [String]>] {
        [
            "font-family": \.fontFamily,
            "font-family-bold": \.fontFamilyBold,
            "font-family-italic": \.fontFamilyItalic,
            "font-family-bold-italic": \.fontFamilyBoldItalic,
        ]
    }

    /// `entries` with a reset in front of the first appearance of each
    /// list-valued key.
    ///
    /// This is what makes a command line *replace* what the config files set
    /// rather than adding to it, which is libghostty's rule and the one thing
    /// about `font-family` that a person cannot work around: every entry
    /// appends, so without this `--font-family=X` would mean "and also X" and
    /// there would be no way to say "X instead" at all.
    ///
    /// Spelled as a synthetic `key = ""` entry rather than as a flag on the
    /// apply path, because `""` already means reset and an entry is a thing
    /// the rest of the loader already knows how to carry: it replays under a
    /// theme, it reports diagnostics with a line number, and it needed no new
    /// argument anywhere. Only the *first* appearance gets one, so two
    /// `--font-family` arguments still build a list between themselves.
    ///
    /// An entry with no value at all gets none. A bare `--font-family` is a
    /// mistake — it is reported as "value required" and sets nothing — and
    /// resetting for it would answer that mistake by silently emptying the
    /// list the config file spent three lines building, leaving a warning
    /// whose text says the argument was *ignored*. libghostty checks for the
    /// value before it touches its own overwrite flag, for the same reason.
    /// The flag stays unarmed, so a later `--font-family=Menlo` is still the
    /// first one seen and still replaces.
    public static func resettingLists(_ entries: [ConfigEntry]) -> [ConfigEntry] {
        var seen: Set<String> = []
        var result: [ConfigEntry] = []
        for entry in entries {
            if entry.value != nil, listValuedKeys[entry.key] != nil,
                seen.insert(entry.key).inserted
            {
                result.append(ConfigEntry(key: entry.key, value: "", line: entry.line))
            }
            result.append(entry)
        }
        return result
    }
}

/// Something wrong with a config file, in the words libghostty uses for the
/// same mistake.
///
/// Warnings, every one of them: a bad line is skipped and the rest of the file
/// is read. A config file is not a program, and refusing to start a terminal
/// over a misspelled option would be a poor trade — especially since the
/// terminal is often the only way to fix the file.
public struct ConfigDiagnostic: Equatable, Sendable, CustomStringConvertible {
    /// The file it was found in, or nil when the text came from somewhere
    /// else.
    public var file: String?
    /// 1-indexed line within `file`.
    public var line: Int?
    /// The key that was being applied, which may be the misspelling itself.
    public var key: String?
    public var message: String

    public init(file: String? = nil, line: Int? = nil, key: String? = nil, message: String) {
        self.file = file
        self.line = line
        self.key = key
        self.message = message
    }

    /// `path:12:font-famly: unknown field`, which is libghostty's own layout
    /// and close enough to a compiler's that an editor will make the path
    /// clickable.
    public var description: String {
        var result = ""
        if let file {
            result += "\(file):"
            if let line { result += "\(line):" }
        }
        if let key, !key.isEmpty {
            result += "\(key): "
        } else if !result.isEmpty {
            result += " "
        }
        return result + message
    }
}
