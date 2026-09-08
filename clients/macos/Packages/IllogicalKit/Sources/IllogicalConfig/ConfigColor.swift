//  ConfigColor.swift
//  A colour, spelled the way Ghostty spells one.
//
//  Ported from libghostty's `terminal/color.zig` — `RGB.parse`,
//  `parsePaletteEntry`, and the `fraction` reader `rgbi:` needs. Everything a
//  theme file can contain goes through here, so "exactly what Ghostty accepts"
//  is not a nicety: a theme is a config file written by somebody else, and the
//  ~600 of them the app ships were authored against that parser. One form we
//  reject is one theme that silently loses a colour.
//
//  The forms, all of them:
//
//    * `#rgb`, `#rrggbb`, `#rrrgggbbb`, `#rrrrggggbbbb` — 4, 8, 12 and 16 bits
//      per channel, scaled down to 8.
//    * `rgb` and `rrggbb` without the `#`, which is Ghostty's own extension for
//      config files and the reason `background = 1e1e2e` works.
//    * `rgb:<r>/<g>/<b>` with 1–4 hex digits per channel, and
//      `rgbi:<r>/<g>/<b>` with decimal fractions — XParseColor's syntax, which
//      is what a program sending OSC 4 uses.
//    * An X11 colour name, matched ASCII case-insensitively.
//
//  Pure Swift, like the rest of this package: it builds and tests without
//  libghostty present. `ConfigColorParityTests` in the app — which does link
//  libghostty — checks this parser against `ghostty_color_parse` over every
//  X11 name and every shape below, so "ported" is a claim with a test behind
//  it rather than a comment.

import Foundation

/// An 8-bit-per-channel colour, as a config file names one.
public struct ConfigColor: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// From a packed `0xRRGGBB`, for the defaults written in source.
    public init(_ hex: UInt32) {
        self.init(
            r: UInt8((hex >> 16) & 0xff),
            g: UInt8((hex >> 8) & 0xff),
            b: UInt8(hex & 0xff))
    }

    /// Parse one of the forms above, or nil.
    ///
    /// Leading and trailing spaces and tabs are ignored — and only those, as
    /// everywhere else in this package: a config value has already been
    /// trimmed by `ConfigSyntax`, but an OSC-style value inside a `palette`
    /// entry has not.
    public static func parse<S: StringProtocol>(_ value: S) -> ConfigColor? {
        let input = value.trimmedASCII
        guard !input.isEmpty else { return nil }

        if input.first == "#" {
            let digits = input.dropFirst()
            switch digits.count {
            case 3, 6, 9, 12: return hexTriple(digits)
            default: return nil
            }
        }

        // Names before bare hex, which is Ghostty's order and matters for
        // exactly one input: `beige` is six characters, all of them hex
        // digits, and is a colour rather than #BE13E5.
        if let named = X11Colors.color(named: input) { return named }

        switch input.count {
        case 3, 6: return hexTriple(input)
        default: break
        }

        return parseXParseColor(input)
    }

    /// `rgb:a/a/a` and `rgbi:0.5/0.5/0.5`.
    private static func parseXParseColor(_ input: Substring) -> ConfigColor? {
        guard input.count >= "rgb:a/a/a".count, input.hasPrefix("rgb") else { return nil }

        var rest = input.dropFirst(3)
        let intensity = rest.first == "i"
        if intensity { rest = rest.dropFirst() }
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst()

        // Exactly two separators, and the last channel is whatever follows the
        // second one — so `rgb:1/2/3/4` fails on the trailing `/4` rather than
        // quietly reading three of four channels.
        let channels = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard channels.count == 3 else { return nil }

        let read: (Substring) -> UInt8? =
            intensity ? { fromIntensity($0) } : { fromHex($0) }
        guard let r = read(channels[0]), let g = read(channels[1]), let b = read(channels[2])
        else { return nil }
        return ConfigColor(r: r, g: g, b: b)
    }

    /// Split `digits` into three equal runs and read each as a channel.
    private static func hexTriple(_ digits: Substring) -> ConfigColor? {
        let width = digits.count / 3
        let first = digits.index(digits.startIndex, offsetBy: width)
        let second = digits.index(first, offsetBy: width)
        guard let r = fromHex(digits[..<first]),
            let g = fromHex(digits[first..<second]),
            let b = fromHex(digits[second...])
        else { return nil }
        return ConfigColor(r: r, g: g, b: b)
    }

    /// One channel of 1–4 hex digits, scaled to 8 bits.
    ///
    /// The scaling is the division libghostty does — `value * 255 / max`,
    /// where `max` is the largest value that many digits can hold — and not a
    /// shift. They differ: `#fff` is 255 either way, but `#800` is 136 by
    /// division and 128 by shifting, and 136 is what every other terminal
    /// draws for it.
    static func fromHex<S: StringProtocol>(_ value: S) -> UInt8? {
        guard !value.isEmpty, value.count <= 4 else { return nil }
        // `UInt16(_:radix:)` accepts a leading `+`/`-` and Unicode digits,
        // neither of which is a hex colour, so the digits are checked first.
        guard value.allSatisfy(\.isHexDigitASCII), let raw = UInt16(value, radix: 16) else {
            return nil
        }
        let divisor: UInt32
        switch value.count {
        case 1: divisor = 0xf
        case 2: divisor = 0xff
        case 3: divisor = 0xfff
        default: divisor = 0xffff
        }
        return UInt8(UInt32(raw) * 255 / divisor)
    }

    /// One channel of `rgbi:`, a decimal fraction in [0, 1].
    ///
    /// `Double(_:)` would take `1e-1`, `0x1p0` and `inf` as well, none of
    /// which XParseColor accepts, so this reads the restricted grammar
    /// libghostty's `fraction.zig` reads: an optional sign, decimal digits, an
    /// optional point, at least one digit, nothing else.
    static func fromIntensity<S: StringProtocol>(_ value: S) -> UInt8? {
        var digits = Substring(value)
        var negative = false
        if digits.first == "+" {
            digits = digits.dropFirst()
        } else if digits.first == "-" {
            negative = true
            digits = digits.dropFirst()
        }

        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ $0.allSatisfy(\.isDigitASCII) }) else {
            return nil
        }
        let whole = parts.first ?? ""
        let fraction = parts.count == 2 ? parts[1] : ""
        guard !(whole.isEmpty && fraction.isEmpty) else { return nil }

        var magnitude = 0.0
        for digit in whole { magnitude = magnitude * 10 + Double(digit.wholeNumberValue!) }
        // Stop at 15 digits, where the numerator and the denominator are both
        // still exact in a Double and the one division below rounds once.
        var numerator = 0.0
        var scale = 1.0
        for digit in fraction where scale < 1e15 {
            numerator = numerator * 10 + Double(digit.wholeNumberValue!)
            scale *= 10
        }
        magnitude += numerator / scale

        let result = negative ? -magnitude : magnitude
        // Written to let -0 through and to reject anything out of range.
        guard result >= 0, result <= 1 else { return nil }
        return UInt8(result * 255)
    }
}

/// A colour that may instead name one the cell already has.
///
/// `cursor-color = cell-foreground` and `selection-background =
/// cell-foreground` are how a config asks for a cursor or a selection that
/// inverts whatever it lands on rather than being one fixed colour, which is
/// the only spelling of that Ghostty has had since 1.2 — `cursor-invert-fg-bg`
/// and `selection-invert-fg-bg` are shims onto this pair.
public enum ConfigTerminalColor: Equatable, Sendable {
    case color(ConfigColor)
    case cellForeground
    case cellBackground

    public static func parse<S: StringProtocol>(_ value: S) -> ConfigTerminalColor? {
        // Untrimmed and case-sensitive, which is libghostty's own comparison:
        // `ConfigSyntax` has trimmed the value already, and the keywords are
        // spelled the way the config keys are.
        if value == "cell-foreground" { return .cellForeground }
        if value == "cell-background" { return .cellBackground }
        guard let color = ConfigColor.parse(value) else { return nil }
        return .color(color)
    }
}

/// The `palette = N=COLOR` overrides, and nothing else.
///
/// Sparse rather than 256 entries deep, and the difference is not only
/// storage: the untouched indices are libghostty's own default palette, which
/// this package cannot see and has no business copying. Resolving that default
/// and generating the cube on top of it is the app's job, where libghostty is
/// linked — `PaletteResolver`.
///
/// Which indices were set is exactly what `palette-generate` needs to know, so
/// the dictionary's keys *are* Ghostty's mask.
public struct ConfigPalette: Equatable, Sendable {
    public private(set) var overrides: [UInt8: ConfigColor] = [:]

    public init() {}

    public subscript(index: UInt8) -> ConfigColor? { overrides[index] }
    public var isEmpty: Bool { overrides.isEmpty }

    public mutating func set(_ index: UInt8, to color: ConfigColor) {
        overrides[index] = color
    }

    public mutating func removeAll() { overrides.removeAll() }

    /// Parse `N=COLOR`, where `N` is 0–255 in decimal unless it carries a
    /// `0x`, `0o` or `0b` prefix, and `COLOR` is anything `ConfigColor` takes.
    ///
    /// Nil for a bad index or a bad colour alike. The caller reports it; the
    /// distinction between "300" and "#gg" is not one a config file's warning
    /// needs to draw.
    public static func parseEntry<S: StringProtocol>(
        _ value: S
    ) -> (index: UInt8, color: ConfigColor)? {
        guard let equals = value.firstIndex(of: "=") else { return nil }
        guard let index = paletteIndex(value[..<equals].trimmedASCII),
            let color = ConfigColor.parse(value[value.index(after: equals)...])
        else { return nil }
        return (index, color)
    }

    /// Zig's `parseInt` with base 0: decimal, or `0x`/`0o`/`0b` prefixed.
    ///
    /// No sign, because a palette index has none, and no `_` separators:
    /// Zig accepts those and Ghostty inherits it, but `palette = 1_0=red` is
    /// not something any theme writes and reading it as 10 would be a
    /// surprise the other way round.
    private static func paletteIndex(_ text: Substring) -> UInt8? {
        var digits = text
        var radix = 10
        if digits.count > 2, digits.first == "0" {
            switch digits[digits.index(after: digits.startIndex)] {
            case "x": radix = 16
            case "o": radix = 8
            case "b": radix = 2
            default: radix = 10
            }
            if radix != 10 { digits = digits.dropFirst(2) }
        }
        guard digits.allSatisfy(\.isHexDigitASCII) else { return nil }
        return UInt8(digits, radix: radix)
    }
}

extension StringProtocol {
    /// Spaces and tabs only, matching libghostty's `whitespace`.
    var trimmedASCII: Substring {
        var result = Substring(self)
        while let first = result.first, first == " " || first == "\t" {
            result = result.dropFirst()
        }
        while let last = result.last, last == " " || last == "\t" {
            result = result.dropLast()
        }
        return result
    }
}

extension Character {
    /// ASCII only. `isHexDigit` is true for Arabic-Indic and fullwidth digits
    /// too, and `UInt16(_:radix:)` accepts them — so `#٧٧٧` would parse as a
    /// colour without this.
    fileprivate var isHexDigitASCII: Bool {
        isASCII && isHexDigit
    }

    fileprivate var isDigitASCII: Bool {
        isASCII && isNumber
    }
}
