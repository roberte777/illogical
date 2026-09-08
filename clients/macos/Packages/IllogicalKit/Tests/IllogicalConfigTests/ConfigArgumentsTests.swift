//  ConfigArgumentsTests.swift
//  The command line, and the one thing it has to do differently from a file.
//
//  Every config entry appends to its list, which is what makes `font-family`
//  a fallback chain rather than four spellings of one name. That rule makes a
//  command line useless on its own: `--font-family=X` would mean "and also
//  X", and there would be no way to say "X instead" at all. So an argument
//  resets the list before it adds to it, and the whole of this file is about
//  that asymmetry and the places it must *not* leak into.

import Foundation
import Testing

@testable import IllogicalConfig

@Suite("Config arguments")
struct ConfigArgumentsTests {
    private struct Home: ~Copyable {
        let url: URL
        var environment: [String: String] { ["HOME": url.path] }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "illogical-args-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        @discardableResult
        func write(_ text: String, to path: String) throws -> URL {
            let file = url.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            return file
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Parsing

    @Test("--key=value is the same entry a config line would make")
    func parsesLongOptions() {
        let entries = ConfigSyntax.entries(ofArguments: ["--font-size=15"])
        #expect(entries == [ConfigEntry(key: "font-size", value: "15", line: 1)])
    }

    @Test("a bare --key has no value, which is 'value required' and not empty")
    func parsesValuelessOption() {
        let entries = ConfigSyntax.entries(ofArguments: ["--font-size"])
        #expect(entries.first?.value == nil)

        // The distinction the file format also makes: `--key=` is empty,
        // which resets, and `--key` is missing, which is a warning.
        #expect(ConfigSyntax.entries(ofArguments: ["--font-size="]).first?.value == "")
    }

    /// The reason the parser skips rather than reports. AppKit adds these to
    /// any app launched from Xcode, and the first argument is always the
    /// executable's own path.
    @Test("anything that is not --key is skipped, not reported")
    func skipsForeignArguments() {
        let entries = ConfigSyntax.entries(ofArguments: [
            "-NSDocumentRevisionsDebugMode", "YES", "-ApplePersistenceIgnoreState",
            "/some/file.txt", "--font-size=15",
        ])
        #expect(entries.map(\.key) == ["font-size"])
    }

    @Test("a bare -- ends the options")
    func endOfOptions() {
        let entries = ConfigSyntax.entries(ofArguments: ["--font-size=15", "--", "--font-size=9"])
        #expect(entries.map(\.value) == ["15"])
    }

    @Test("quotes come off the same way they do in a file")
    func stripsQuotes() {
        let entries = ConfigSyntax.entries(ofArguments: ["--font-family=\"Berkeley Mono\""])
        #expect(entries.first?.value == "Berkeley Mono")
        #expect(ConfigSyntax.entries(ofArguments: ["--font-family=\"\""]).first?.value == "")
    }

    /// The number is printed back at whoever typed it, so it counts over
    /// everything handed in — including the arguments that produced no entry.
    @Test("the line number is the argument's own position")
    func countsSkippedArguments() {
        let entries = ConfigSyntax.entries(ofArguments: ["-Foo", "bar", "--font-size=15"])
        #expect(entries.first?.line == 3)
    }

    // MARK: - The reset

    @Test("a list-valued key gets a reset in front of its first appearance only")
    func resetsListsOnce() {
        let given = ConfigSyntax.entries(ofArguments: [
            "--font-family=A", "--font-family=B", "--font-size=15",
        ])
        let expanded = Config.resettingLists(given)
        #expect(
            expanded.map { "\($0.key)=\($0.value ?? "<nil>")" } == [
                "font-family=", "font-family=A", "font-family=B", "font-size=15",
            ])
    }

    @Test("a scalar key is left alone")
    func doesNotResetScalars() {
        let given = ConfigSyntax.entries(ofArguments: ["--font-size=15", "--font-size=16"])
        #expect(Config.resettingLists(given) == given)
    }

    /// `listValuedKeys` is a hand-written set beside the switch that routes
    /// these keys, so this is what says the two have not drifted: every key
    /// in it must actually append on a repeat, and a key outside it must not.
    @Test("every key in listValuedKeys is one that appends, and others do not")
    func listValuedKeysAreTheOnesThatAppend() {
        for key in Config.listValuedKeys {
            var config = Config()
            var diagnostics: [ConfigDiagnostic] = []
            config.apply(ConfigEntry(key: key, value: "A", line: 1), diagnostics: &diagnostics)
            config.apply(ConfigEntry(key: key, value: "B", line: 2), diagnostics: &diagnostics)
            #expect(diagnostics.isEmpty, "\(key) reported \(diagnostics)")

            let lists = [
                config.fontFamily, config.fontFamilyBold, config.fontFamilyItalic,
                config.fontFamilyBoldItalic,
            ]
            #expect(lists.contains(["A", "B"]), "\(key) did not append")
        }

        var scalar = Config()
        var diagnostics: [ConfigDiagnostic] = []
        scalar.apply(ConfigEntry(key: "font-size", value: "15", line: 1), diagnostics: &diagnostics)
        scalar.apply(ConfigEntry(key: "font-size", value: "16", line: 2), diagnostics: &diagnostics)
        #expect(scalar.fontSize == 16)
        #expect(!Config.listValuedKeys.contains("font-size"))
    }

    // MARK: - Through the loader

    private func load(
        _ file: String, arguments: [String], home: borrowing Home
    ) throws -> ConfigLoad {
        let path = try home.write(file, to: ".config/illogical/config")
        return Config.load(
            files: [path], environment: home.environment, arguments: arguments)
    }

    /// The whole point. A file naming two families and a command line naming
    /// one leaves the one, not three.
    @Test("a command line replaces the file's list rather than extending it")
    func argumentsReplaceFileLists() throws {
        let home = try Home()
        let result = try load(
            """
            font-family = Berkeley Mono
            font-family = Noto Sans CJK
            """,
            arguments: ["--font-family=Menlo"], home: home)
        #expect(result.config.fontFamily == ["Menlo"])
    }

    /// And two of them still build a list between themselves, which is what
    /// makes the reset "once" rather than "each".
    @Test("two arguments for the same key still build a list")
    func argumentsBuildTheirOwnList() throws {
        let home = try Home()
        let result = try load(
            "font-family = Berkeley Mono",
            arguments: ["--font-family=Menlo", "--font-family=Courier New"], home: home)
        #expect(result.config.fontFamily == ["Menlo", "Courier New"])
    }

    @Test("an empty argument list changes nothing")
    func noArgumentsIsUnchanged() throws {
        let home = try Home()
        let file = "font-family = Berkeley Mono\nfont-size = 15"
        let result = try load(file, arguments: [], home: home)
        #expect(result.config.fontFamily == ["Berkeley Mono"])
        #expect(result.config.fontSize == 15)
    }

    @Test("a scalar given on the command line outranks the file")
    func argumentsOutrankFilesForScalars() throws {
        let home = try Home()
        let result = try load(
            "font-size = 15", arguments: ["--font-size=22"], home: home)
        #expect(result.config.fontSize == 22)
    }

    /// `finalize` runs after the command line, not before it, so a family
    /// given here still fills in the styles nobody named. Applying arguments
    /// after that step would leave bold pointing at the file's family.
    @Test("the styles are filled in from a family the command line gave")
    func finalizeSeesArguments() throws {
        let home = try Home()
        let result = try load(
            "font-family = Berkeley Mono", arguments: ["--font-family=Menlo"], home: home)
        #expect(result.config.fontFamily == ["Menlo"])
        #expect(result.config.fontFamilyBold == ["Menlo"])
        #expect(result.config.fontFamilyItalic == ["Menlo"])
        #expect(result.config.fontFamilyBoldItalic == ["Menlo"])
    }

    /// A misspelling is reported against the argument rather than against a
    /// file that does not contain it. `file` is nil, so the description has
    /// no path and no line — naming a config file for a typo on the command
    /// line would send somebody to the wrong place entirely.
    @Test("a bad argument is reported without blaming a file")
    func diagnosticsDoNotNameAFile() throws {
        let home = try Home()
        let result = try load("", arguments: ["--font-famly=Menlo"], home: home)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.file == nil)
        #expect(diagnostic.key == "font-famly")
        #expect(diagnostic.description == "font-famly: unknown field")
    }

    /// A `--key` with no value is the same warning a config line with no `=`
    /// gets, and not a silent empty.
    @Test("a valueless argument reports rather than resetting")
    func valuelessArgumentReports() throws {
        let home = try Home()
        let result = try load("font-size = 15", arguments: ["--font-size"], home: home)
        #expect(result.config.fontSize == 15)
        #expect(result.diagnostics.contains { $0.message == "value required" })
    }
}
