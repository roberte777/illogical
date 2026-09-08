//  ConfigSyntax.swift
//  The config file's line format: `key = value`, and nothing else.
//
//  Ported from libghostty's `cli/args.zig` — `LineIterator` plus the parts of
//  `parseIntoField` that decide what a value *means*. libghostty turns each
//  line back into a `--key=value` argument and hands it to the same parser its
//  CLI uses, which is why the format has no sections, no nesting and no types:
//  every line is an argument someone could equally have typed.
//
//  We have no CLI to share with, so the seam is here instead. The rules are
//  the same rules, and they are small enough to be worth stating in full:
//
//    * A line is trimmed, then split at its *first* `=`. Spacing around the
//      `=` is not significant.
//    * A line beginning with `#` is a comment. A `#` anywhere else is part of
//      the value — `background = #123abc` is a colour, not a comment, and
//      that is the reason trailing comments cannot exist.
//    * A value wrapped in double quotes has them stripped. This is how a
//      value keeps leading or trailing spaces, and how `""` is written.
//    * A key with an `=` and nothing after it has an *empty* value, which is
//      distinct from a key with no `=` at all. The first resets to the
//      default; the second is missing its value. `Config` decides that; this
//      file only preserves the difference.

import Foundation

/// One `key = value` line, and where it came from.
public struct ConfigEntry: Equatable, Sendable {
    /// The text left of the `=`, trimmed. Never trimmed to nothing by us: a
    /// line that is entirely whitespace never gets this far.
    public var key: String

    /// The text right of the `=`, trimmed and unquoted. Nil when the line had
    /// no `=` at all — a distinction `Config.apply` reports as "value
    /// required" rather than silently reading as empty.
    public var value: String?

    /// 1-indexed, and counted over the raw file including the blank and
    /// comment lines that produced no entry. It exists to be printed back at
    /// the person who wrote the file, so it has to match what their editor
    /// shows them.
    public var line: Int

    public init(key: String, value: String?, line: Int) {
        self.key = key
        self.value = value
        self.line = line
    }
}

public enum ConfigSyntax {
    /// Every `key = value` in `text`, in file order.
    ///
    /// Total: there is no such thing as a malformed line here. A line we
    /// cannot make sense of still yields an entry, and `Config.apply` is what
    /// says so with a diagnostic that has a line number on it. Splitting it
    /// that way keeps every message about a *key* in one place.
    public static func entries(of text: String) -> [ConfigEntry] {
        var entries: [ConfigEntry] = []
        var number = 0

        // A UTF-8 byte order mark decodes to this, and would otherwise be part
        // of the first key — so `font-family` on line 1 of a file some editors
        // wrote would be an unknown field, and the file would look ignored.
        var body = Substring(text)
        if body.first == "\u{FEFF}" { body = body.dropFirst() }

        // `isNewline` rather than `"\n"`, because in Swift `"\r\n"` is a
        // single Character: splitting on `"\n"` alone leaves a file written on
        // Windows as one enormous line, and every key in it unknown.
        //
        // `omittingEmptySubsequences: false` so blank lines still advance the
        // count. A line number that drifts past the first blank line is worse
        // than no line number.
        for raw in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            number += 1

            let line = raw.trimmed
            if line.isEmpty || line.first == "#" { continue }

            guard let equals = line.firstIndex(of: "=") else {
                entries.append(ConfigEntry(key: String(line), value: nil, line: number))
                continue
            }

            let key = line[..<equals].trimmed
            var value = line[line.index(after: equals)...].trimmed

            // Only a matching *pair* of quotes, and only around the whole
            // value: `"a"b"` keeps its quotes. libghostty checks the same two
            // characters, and the looseness is deliberate on both sides —
            // this is a quote-stripping rule, not a string grammar, and a
            // font family with a quote in its name does not exist.
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = value.dropFirst().dropLast()
            }

            entries.append(ConfigEntry(key: String(key), value: String(value), line: number))
        }

        return entries
    }

    /// Every `--key=value` in `arguments`, in the order they were given.
    ///
    /// The same `ConfigEntry` a config file line produces, because they are
    /// the same thing: libghostty turns each config line back into a
    /// `--key=value` argument and hands it to the parser its CLI already
    /// uses. We came at it from the other end and parse arguments into the
    /// line format instead, but the seam is in the same place and the
    /// vocabulary is identical.
    ///
    /// Only `--key=value` and a bare `--key`. Not `--key value`: a Mac app is
    /// handed arguments by whoever launched it, and a two-token form cannot
    /// tell `--font-family Berkeley` from `--font-family` followed by a file
    /// the Finder appended. The bare form yields a nil value, which `Config`
    /// reports as "value required" exactly as it does for a config line with
    /// no `=`.
    ///
    /// Anything not starting with `--` is skipped rather than reported, and
    /// that is load-bearing rather than lax: the first argument is the
    /// executable's own path, and AppKit adds its own single-dash pairs
    /// (`-NSDocumentRevisionsDebugMode YES`, `-ApplePersistenceIgnoreState`)
    /// to any app launched from Xcode. Reporting those would mean a warning
    /// per launch about a flag nobody typed.
    ///
    /// A bare `--` ends the options, in the usual way.
    ///
    /// `line` is the argument's position, counted from 1 over everything
    /// passed in including what was skipped, so it points at the argument a
    /// person actually typed.
    public static func entries(ofArguments arguments: [String]) -> [ConfigEntry] {
        var entries: [ConfigEntry] = []

        for (offset, argument) in arguments.enumerated() {
            if argument == "--" { break }
            guard argument.hasPrefix("--") else { continue }

            let body = argument.dropFirst(2)
            if body.isEmpty { continue }

            guard let equals = body.firstIndex(of: "=") else {
                entries.append(
                    ConfigEntry(key: String(body.trimmed), value: nil, line: offset + 1))
                continue
            }

            let key = body[..<equals].trimmed
            var value = body[body.index(after: equals)...].trimmed
            // The same quote-stripping a config line gets. A shell usually
            // eats the quotes first, but `--font-family=""` typed into a
            // launcher that does not is the documented way to say "empty".
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = value.dropFirst().dropLast()
            }

            entries.append(
                ConfigEntry(key: String(key), value: String(value), line: offset + 1))
        }

        return entries
    }

    /// A flag's value, in libghostty's spelling. Nil when it is neither.
    ///
    /// Its set exactly (`cli/args.zig`), which is smaller than it looks:
    /// `true` and `false` written out, `1` and `0`, and a bare `t` or `f` in
    /// either case — but not `T`rue, and not `yes`, `on` or `enabled`. A
    /// config file that says one of those was written for something else, and
    /// a warning is more use to whoever wrote it than a guess would be.
    public static func bool(_ value: String) -> Bool? {
        switch value {
        case "1", "t", "T", "true": return true
        case "0", "f", "F", "false": return false
        default: return nil
        }
    }

    /// `background-blur`'s value as a radius in pixels, which libghostty
    /// spells as a bool *or* a number. Nil when it is neither.
    ///
    /// 20 for the bare `true`, which is the radius libghostty picks for the
    /// same word, so that the two files agree about what "on" looks like and
    /// not merely about how to spell it. The bool spellings are its set too.
    ///
    /// Capped at 255. The call this ends up in takes a C `int` and the blur
    /// stops getting visibly heavier long before that; a four-digit radius is
    /// a typo, and clamping it beats handing the window server a number it
    /// will spend real time on.
    public static func blurRadius(_ value: String) -> Int? {
        switch value.lowercased() {
        case "true", "yes", "y", "t": return 20
        case "false", "no", "n", "f": return 0
        default:
            guard let radius = Int(value), radius >= 0 else { return nil }
            return min(radius, 255)
        }
    }
}

extension Substring {
    /// Spaces and tabs, plus a stray carriage return — the split above
    /// already ate the one in a CRLF, but not a lone `\r` in the middle of a
    /// line.
    ///
    /// libghostty's `whitespace` is `" \t"` exactly, and not Unicode
    /// whitespace: a non-breaking space in a config file is a character in
    /// the value, which is what makes a font family that contains one work.
    fileprivate var trimmed: Substring {
        var result = self
        while let first = result.first, first == " " || first == "\t" || first == "\r" {
            result = result.dropFirst()
        }
        while let last = result.last, last == " " || last == "\t" || last == "\r" {
            result = result.dropLast()
        }
        return result
    }
}
