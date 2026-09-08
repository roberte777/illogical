//  ConfigTheme.swift
//  `theme = Catppuccin Mocha`, and the light/dark pair.
//
//  Ported from libghostty's `Config.Theme` (`config/Config.zig`). A theme is
//  the name of a file, and that file is an ordinary config file holding
//  colours — which is the whole trick, and why this is a small type: there is
//  no theme *format*, so there is nothing to parse but the name.
//
//  One value or two. `theme = Nord` uses Nord whatever the desktop is doing;
//  `theme = light:Rose Pine Dawn,dark:Rose Pine` picks by the current
//  appearance. Order does not matter and both halves are required — a lone
//  `light:` is an error rather than half a pair, because the other half would
//  have to fall back to something and no answer to "what" is a good one.

import Foundation

/// Which of a light/dark pair applies.
public enum ConfigAppearance: Sendable {
    case light
    case dark
}

/// The theme, or themes, a config named.
public struct ConfigTheme: Equatable, Sendable {
    public var light: String
    public var dark: String

    public init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }

    /// Both halves the same, which is what a bare `theme = Nord` means.
    public init(_ name: String) {
        self.init(light: name, dark: name)
    }

    public func name(for appearance: ConfigAppearance) -> String {
        switch appearance {
        case .light: return light
        case .dark: return dark
        }
    }

    /// Whether the two halves differ, which is the only case where the
    /// appearance is worth watching.
    public var isConditional: Bool { light != dark }

    /// Parse `Nord`, or `light:Rose Pine Dawn,dark:Rose Pine`.
    ///
    /// A `,`, `:` or `=` anywhere in the value is what switches to the pair
    /// form — including `=`, which is not valid for it, because a `theme =
    /// light=foo,dark=bar` is somebody reaching for the pair and missing
    /// rather than somebody naming a file with an equals sign in it.
    /// libghostty makes the same allowance for the same reason.
    public static func parse<S: StringProtocol>(_ value: S) -> ConfigTheme? {
        let input = value.trimmedASCII
        guard !input.isEmpty else { return nil }
        guard input.contains(",") || input.contains(":") || input.contains("=") else {
            return ConfigTheme(String(input))
        }

        var light: String?
        var dark: String?
        for field in input.split(separator: ",") {
            guard let separator = field.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
                return nil
            }
            let key = field[..<separator].trimmedASCII
            let name = String(field[field.index(after: separator)...].trimmedASCII)
            guard !name.isEmpty else { return nil }
            switch key {
            case "light":
                guard light == nil else { return nil }
                light = name
            case "dark":
                guard dark == nil else { return nil }
                dark = name
            default:
                return nil
            }
        }

        guard let light, let dark else { return nil }
        return ConfigTheme(light: light, dark: dark)
    }

    /// Expand a leading `~` in either half, so that `theme = ~/themes/mine`
    /// is a path and not a file called `~`.
    public func expandingHome(_ home: URL) -> ConfigTheme {
        ConfigTheme(light: Self.expand(light, home), dark: Self.expand(dark, home))
    }

    private static func expand(_ path: String, _ home: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home.appending(path: String(path.dropFirst(1))).path
    }
}
