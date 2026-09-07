//  ConfigLoadTests.swift
//  Finding the files, reading them, and creating one when there are none.
//
//  Every test here drives a temporary `$HOME`. That is the whole reason
//  `ConfigPath` takes an environment dictionary rather than asking Foundation
//  for the home directory: a test that read the real one would create a real
//  config file in the person's Application Support directory the first time it
//  ran, and pass ever after.

import Foundation
import Testing

@testable import IllogicalConfig

@Suite("Config loading")
struct ConfigLoadTests {
    /// A throwaway `$HOME`, removed when the test ends.
    private struct Home: ~Copyable {
        let url: URL
        var environment: [String: String] { ["HOME": url.path] }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "illogical-config-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        /// Write `text` at `path` relative to this home, creating the
        /// directories above it.
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

    private static let bundleID = "dev.illogical.Illogical"
    private static let xdgPath = ".config/illogical/config"
    private static let appSupportPath =
        "Library/Application Support/dev.illogical.Illogical/config"

    // MARK: - Paths

    @Test("the XDG file is ~/.config/illogical/config")
    func xdgDefault() throws {
        let home = try Home()
        #expect(
            ConfigPath.xdg(environment: home.environment).path
                == home.url.appending(path: Self.xdgPath).path)
    }

    @Test("XDG_CONFIG_HOME moves it, and an empty one does not")
    func xdgOverride() throws {
        let home = try Home()
        var environment = home.environment
        environment["XDG_CONFIG_HOME"] = "/tmp/xdg"
        #expect(ConfigPath.xdg(environment: environment).path == "/tmp/xdg/illogical/config")

        environment["XDG_CONFIG_HOME"] = ""
        #expect(
            ConfigPath.xdg(environment: environment).path
                == home.url.appending(path: Self.xdgPath).path)
    }

    @Test("the app's own file is under Application Support, by bundle identifier")
    func applicationSupport() throws {
        let home = try Home()
        let file = ConfigPath.applicationSupport(
            bundleID: Self.bundleID, environment: home.environment)
        #expect(file?.path == home.url.appending(path: Self.appSupportPath).path)
        // No bundle identifier — `swift test`, a command-line tool — means no
        // Application Support file rather than one under a made-up name.
        #expect(ConfigPath.applicationSupport(bundleID: nil, environment: home.environment) == nil)
    }

    @Test("XDG is read first, so Application Support wins")
    func order() throws {
        let home = try Home()
        let files = ConfigPath.defaults(bundleID: Self.bundleID, environment: home.environment)
        #expect(
            files.map(\.path) == [
                home.url.appending(path: Self.xdgPath).path,
                home.url.appending(path: Self.appSupportPath).path,
            ])
    }

    @Test("ILLOGICAL_CONFIG replaces both, and an empty one reads nothing")
    func overrideVariable() throws {
        let home = try Home()
        var environment = home.environment
        environment[ConfigPath.overrideVariable] = "/tmp/somewhere/config"
        #expect(
            ConfigPath.defaults(bundleID: Self.bundleID, environment: environment).map(\.path)
                == ["/tmp/somewhere/config"])

        environment[ConfigPath.overrideVariable] = ""
        #expect(ConfigPath.defaults(bundleID: Self.bundleID, environment: environment).isEmpty)
    }

    // MARK: - Reading

    @Test("a machine with no config file gets the defaults")
    func noFiles() throws {
        let home = try Home()
        let result = Config.load(
            files: ConfigPath.defaults(bundleID: Self.bundleID, environment: home.environment))
        #expect(result.config == Config())
        #expect(result.sources.isEmpty)
        // A file that is not there is the common case, not a problem.
        #expect(result.diagnostics.isEmpty)
    }

    @Test("both files are read, and the second appends to the first")
    func bothFiles() throws {
        let home = try Home()
        try home.write("font-family = Iosevka\n", to: Self.xdgPath)
        try home.write("font-family = Noto Sans CJK\nfont-size = 15\n", to: Self.appSupportPath)

        let result = Config.load(
            files: ConfigPath.defaults(bundleID: Self.bundleID, environment: home.environment))
        // Appends rather than replaces: a second file is not different from a
        // second line. `font-family = ""` is how you mean "replace".
        #expect(result.config.fontFamily == ["Iosevka", "Noto Sans CJK"])
        #expect(result.config.fontSize == 15)
        #expect(result.sources.count == 2)
    }

    @Test("the later file can clear what the earlier one set")
    func laterFileResets() throws {
        let home = try Home()
        try home.write("font-family = Iosevka\n", to: Self.xdgPath)
        try home.write("font-family = \"\"\nfont-family = Berkeley Mono\n", to: Self.appSupportPath)

        let result = Config.load(
            files: ConfigPath.defaults(bundleID: Self.bundleID, environment: home.environment))
        #expect(result.config.fontFamily == ["Berkeley Mono"])
    }

    @Test("styles are settled once, after the last file")
    func finalizeRunsOnce() throws {
        let home = try Home()
        // If `finalize` ran per file, the bold list would have been filled
        // from Iosevka before the second file was read, and Berkeley Mono
        // would never reach it.
        try home.write("font-family = Iosevka\n", to: Self.xdgPath)
        try home.write("font-family = \"\"\nfont-family = Berkeley Mono\n", to: Self.appSupportPath)

        let result = Config.load(
            files: ConfigPath.defaults(bundleID: Self.bundleID, environment: home.environment))
        #expect(result.config.fontFamilyBold == ["Berkeley Mono"])
    }

    @Test("diagnostics name the file they came from")
    func diagnosticsCarryTheFile() throws {
        let home = try Home()
        let file = try home.write("font-famly = Iosevka\n", to: Self.xdgPath)

        let result = Config.load(
            files: ConfigPath.defaults(bundleID: Self.bundleID, environment: home.environment))
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.file == file.path)
        #expect(result.diagnostics.first?.description == "\(file.path):1:font-famly: unknown field")
    }

    @Test("a directory where the file should be is reported, not ignored")
    func directoryInstead() throws {
        let home = try Home()
        let file = home.url.appending(path: Self.xdgPath)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

        let result = Config.load(files: [file])
        #expect(result.sources.isEmpty)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.file == file.path)
    }

    @Test("an empty file is a file: it loads, and nothing is created over it")
    func emptyFile() throws {
        let home = try Home()
        try home.write("", to: Self.appSupportPath)

        let result = Config.loadDefaults(bundleID: Self.bundleID, environment: home.environment)
        #expect(result.config == Config())
        #expect(result.sources.count == 1)
        #expect(result.created == nil)
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - The template

    @Test("a machine with no config file gets a template, in Application Support")
    func templateCreated() throws {
        let home = try Home()
        let result = Config.loadDefaults(bundleID: Self.bundleID, environment: home.environment)

        let file = home.url.appending(path: Self.appSupportPath)
        #expect(result.created?.path == file.path)
        #expect(FileManager.default.fileExists(atPath: file.path))

        // It sets nothing. Every line is a comment or blank, so what the app
        // does on the next launch is exactly what it did on this one.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(file.path))
        let load = Config.load(files: [file])
        #expect(load.config == Config())
        #expect(load.diagnostics.isEmpty)
    }

    @Test("a machine that already has a file is left alone")
    func templateNotCreatedOverAFile() throws {
        let home = try Home()
        try home.write("font-size = 15\n", to: Self.xdgPath)

        let result = Config.loadDefaults(bundleID: Self.bundleID, environment: home.environment)
        #expect(result.created == nil)
        #expect(result.config.fontSize == 15)
        // Not even in the other location: one file anywhere is a configured
        // machine.
        #expect(
            !FileManager.default.fileExists(
                atPath: home.url.appending(path: Self.appSupportPath).path))
    }

    @Test("ILLOGICAL_CONFIG creates nothing")
    func templateNotCreatedUnderOverride() throws {
        let home = try Home()
        var environment = home.environment
        environment[ConfigPath.overrideVariable] = home.url.appending(path: "named/config").path

        let result = Config.loadDefaults(bundleID: Self.bundleID, environment: environment)
        #expect(result.created == nil)
        #expect(result.sources.isEmpty)
        // Somebody who names a path means that path. A template at the
        // default location would be a file they are not looking at.
        #expect(
            !FileManager.default.fileExists(
                atPath: home.url.appending(path: Self.appSupportPath).path))
    }

    @Test("writing a template never truncates a file that appeared underneath it")
    func templateDoesNotOverwrite() throws {
        let home = try Home()
        let file = try home.write("font-size = 15\n", to: Self.appSupportPath)
        #expect(try ConfigTemplate.write(to: file) == false)
        #expect(try String(contentsOf: file, encoding: .utf8) == "font-size = 15\n")
    }
}
