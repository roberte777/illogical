//  ConfigSyntaxTests.swift
//  The line format, against libghostty's own rules.
//
//  Most of these come straight from the crash course in Ghostty's template
//  file — the four spellings of `key = value`, the `#` that is a colour rather
//  than a comment, the empty value that resets. They are the promises the
//  format makes to somebody who already has a `~/.config/ghostty/config`, so
//  they are worth pinning one by one.

import Testing

@testable import IllogicalConfig

@Suite("Config syntax")
struct ConfigSyntaxTests {
    @Test("spacing around the equals sign does not matter")
    func spacing() {
        for text in ["key=value", "key= value", "key =value", "key = value", "  key = value  "] {
            let entries = ConfigSyntax.entries(of: text)
            #expect(entries == [ConfigEntry(key: "key", value: "value", line: 1)])
        }
    }

    @Test("a leading # is a comment, and only a leading one")
    func comments() {
        let entries = ConfigSyntax.entries(
            of: """
                # a comment
                   # an indented comment
                background = #123abc
                """)
        // The value keeps its #. This is why trailing comments cannot exist.
        #expect(entries == [ConfigEntry(key: "background", value: "#123abc", line: 3)])
    }

    @Test("blank and comment lines still advance the line number")
    func lineNumbers() {
        let entries = ConfigSyntax.entries(
            of: """
                # one

                font-size = 12

                font-family = Iosevka
                """)
        #expect(entries.map(\.line) == [3, 5])
    }

    @Test("quotes around a whole value are stripped")
    func quotes() {
        #expect(ConfigSyntax.entries(of: "key = \"value\"").first?.value == "value")
        // The reason quoting exists: a value that is nothing but spaces, and
        // the empty value that resets a list.
        #expect(ConfigSyntax.entries(of: "key = \" pad \"").first?.value == " pad ")
        #expect(ConfigSyntax.entries(of: "key = \"\"").first?.value == "")
        // Not a string grammar. An unmatched quote is part of the value.
        #expect(ConfigSyntax.entries(of: "key = \"value").first?.value == "\"value")
        #expect(ConfigSyntax.entries(of: "key = a\"b\"c").first?.value == "a\"b\"c")
    }

    @Test("the split is at the first equals sign")
    func firstEquals() {
        // `font-feature = ss01=1` is the shape this protects: the value has
        // its own syntax and an equals sign in it.
        #expect(ConfigSyntax.entries(of: "key = a=b").first?.value == "a=b")
    }

    @Test("an equals sign with nothing after it is an empty value, not a missing one")
    func emptyVersusMissing() {
        #expect(ConfigSyntax.entries(of: "key =").first?.value == "")
        #expect(ConfigSyntax.entries(of: "key").first?.value == nil)
    }

    @Test("CRLF line endings are not part of the value")
    func carriageReturns() {
        let entries = ConfigSyntax.entries(of: "font-family = Iosevka\r\nfont-size = 12\r\n")
        #expect(entries.map(\.value) == ["Iosevka", "12"])
    }

    @Test("a UTF-8 byte order mark is not part of the first key")
    func byteOrderMark() {
        let entries = ConfigSyntax.entries(of: "\u{FEFF}font-size = 12")
        #expect(entries == [ConfigEntry(key: "font-size", value: "12", line: 1)])
    }
}
