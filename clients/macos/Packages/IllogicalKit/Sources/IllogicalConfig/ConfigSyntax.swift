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
