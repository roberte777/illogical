//  ThemeTests.swift
//  `theme = <name>`: the name, the file it finds, and what beats what.
//
//  The precedence tests are the ones worth reading. A theme is applied under
//  the config that named it, whatever order the two are written in, which is
//  the one behaviour of this option somebody would notice being wrong — you
//  set a theme, override one colour out of it, and either that works or it
//  silently does not.

import Foundation
import Testing

@testable import IllogicalConfig

@Suite("Theme")
struct ThemeTests {
    // MARK: - The value

    @Test("one name is both halves")
    func singleName() {
        #expect(ConfigTheme.parse("Nord") == ConfigTheme(light: "Nord", dark: "Nord"))
        #expect(ConfigTheme.parse("  Catppuccin Mocha  ")?.dark == "Catppuccin Mocha")
        #expect(ConfigTheme.parse("Nord")?.isConditional == false)
    }

    @Test("light and dark, in either order and however spaced")
    func pair() {
        let expected = ConfigTheme(light: "Rose Pine Dawn", dark: "Rose Pine")
        #expect(ConfigTheme.parse("light:Rose Pine Dawn,dark:Rose Pine") == expected)
        #expect(ConfigTheme.parse("dark:Rose Pine,light:Rose Pine Dawn") == expected)
        #expect(ConfigTheme.parse(" light : Rose Pine Dawn ,  dark : Rose Pine ") == expected)
        // `=` is not the separator for this, but reaching for it is a common
        // enough slip that libghostty takes it too.
        #expect(ConfigTheme.parse("light=Rose Pine Dawn,dark=Rose Pine") == expected)
        #expect(expected.isConditional)
    }

    @Test("half a pair is not a pair")
    func incompletePair() {
        #expect(ConfigTheme.parse("light:foo") == nil)
        #expect(ConfigTheme.parse("dark:foo") == nil)
        #expect(ConfigTheme.parse("light:foo,light:bar") == nil)
        #expect(ConfigTheme.parse("light:foo,medium:bar") == nil)
        #expect(ConfigTheme.parse("light:,dark:bar") == nil)
        #expect(ConfigTheme.parse("") == nil)
    }

    @Test("a name is picked by the appearance")
    func appearance() {
        let theme = ConfigTheme(light: "Day", dark: "Night")
        #expect(theme.name(for: .light) == "Day")
        #expect(theme.name(for: .dark) == "Night")
    }

    @Test("a leading ~ is the home directory")
    func tilde() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(ConfigTheme("~/themes/mine").expandingHome(home).dark == "/Users/x/themes/mine")
        // Only a leading one, and only as a whole component: a file called
        // `~weird` is a file called `~weird`.
        #expect(ConfigTheme("~weird").expandingHome(home).dark == "~weird")
        #expect(ConfigTheme("a/~/b").expandingHome(home).dark == "a/~/b")
    }

    // MARK: - Files

    /// A home directory, a bundle, and the three theme locations inside them.
    private struct Tree {
        let root: URL
        let environment: [String: String]
        static let bundleID = "dev.illogical.Test"

        init() throws {
            root = URL(
                fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
            ).appending(path: "illogical-themes-\(UUID().uuidString)")
            environment = ["HOME": root.appending(path: "home").path]
            for directory in [xdg, appSupport, resourcesThemes] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            }
        }

        var home: URL { root.appending(path: "home") }
        var xdg: URL { home.appending(path: ".config/illogical/themes") }
        var appSupport: URL {
            home.appending(path: "Library/Application Support/\(Self.bundleID)/themes")
        }
        var resources: URL { root.appending(path: "Illogical.app/Contents/Resources") }
        var resourcesThemes: URL { resources.appending(path: "themes") }

        func write(_ text: String, to file: URL) throws {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        /// A config file in the XDG location, and the load of it.
        func load(_ config: String, appearance: ConfigAppearance = .dark) throws -> ConfigLoad {
            let file = home.appending(path: ".config/illogical/config")
            try write(config, to: file)
            return Config.load(
                files: [file], bundleID: Self.bundleID, resources: resources,
                appearance: appearance, environment: environment)
        }

        func resolve(_ name: String) -> ThemePath.Resolution {
            ThemePath.resolve(
                name, bundleID: Self.bundleID, resources: resources, environment: environment)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("the bundled theme is found when nothing overrides it")
    func bundledTheme() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.write("background = #111111", to: tree.resourcesThemes.appending(path: "Nord"))

        #expect(tree.resolve("Nord") == .file(tree.resourcesThemes.appending(path: "Nord")))
        #expect(try tree.load("theme = Nord").config.background == ConfigColor(0x11_11_11))
    }

    @Test("a theme of your own wins over one we shipped, by having the same name")
    func userThemeWins() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.write("background = #111111", to: tree.resourcesThemes.appending(path: "Nord"))
        try tree.write("background = #222222", to: tree.appSupport.appending(path: "Nord"))
        try tree.write("background = #333333", to: tree.xdg.appending(path: "Nord"))

        #expect(try tree.load("theme = Nord").config.background == ConfigColor(0x33_33_33))
    }

    @Test("an absolute path skips the search")
    func absolutePath() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        let file = tree.root.appending(path: "elsewhere/mine")
        try tree.write("background = #444444", to: file)

        #expect(try tree.load("theme = \(file.path)").config.background == ConfigColor(0x44_44_44))
    }

    @Test("a relative path with a separator in it is refused rather than resolved")
    func pathSeparator() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        let result = tree.resolve("../../etc/passwd")
        guard case .missing(let diagnostics) = result else {
            Issue.record("resolved a path with separators")
            return
        }
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("cannot include path separators"))
    }

    @Test("a theme that is not there names every path it looked in")
    func missingTheme() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        let load = try tree.load("theme = Nope")
        #expect(load.diagnostics.count == 3)
        #expect(load.diagnostics.allSatisfy { $0.message.contains("theme \"Nope\" not found") })
        #expect(load.diagnostics.contains { $0.message.contains(tree.xdg.path) })
        #expect(load.diagnostics.contains { $0.message.contains(tree.resourcesThemes.path) })
        // And the rest of the file still applies.
        #expect(try tree.load("theme = Nope\nfont-size = 20").config.fontSize == 20)
    }

    @Test("a directory where a theme should be is stepped over, not stopped at")
    func directoryInTheWay() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try FileManager.default.createDirectory(
            at: tree.xdg.appending(path: "Nord"), withIntermediateDirectories: true)
        try tree.write("background = #111111", to: tree.resourcesThemes.appending(path: "Nord"))

        #expect(try tree.load("theme = Nord").config.background == ConfigColor(0x11_11_11))
    }

    // MARK: - Precedence

    @Test("an explicit colour beats the theme's, written after it")
    func overrideAfter() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.write(
            "background = #111111\nforeground = #eeeeee",
            to: tree.resourcesThemes.appending(path: "Nord"))

        let load = try tree.load(
            """
            theme = Nord
            background = #ff0000
            """)
        #expect(load.config.background == ConfigColor(0xFF_00_00))
        // And everything it did not override still comes from the theme.
        #expect(load.config.foreground == ConfigColor(0xEE_EE_EE))
    }

    /// The one that a straightforward implementation gets wrong: the theme is
    /// named *after* the colour it must not clobber.
    @Test("and written before it")
    func overrideBefore() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.write(
            "background = #111111\nforeground = #eeeeee",
            to: tree.resourcesThemes.appending(path: "Nord"))

        let load = try tree.load(
            """
            background = #ff0000
            theme = Nord
            """)
        #expect(load.config.background == ConfigColor(0xFF_00_00))
        #expect(load.config.foreground == ConfigColor(0xEE_EE_EE))
    }

    @Test("a palette entry from the config beats the theme's, index by index")
    func palettePrecedence() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.write(
            """
            palette = 0=#111111
            palette = 1=#222222
            """, to: tree.resourcesThemes.appending(path: "Nord"))

        let load = try tree.load(
            """
            theme = Nord
            palette = 1=#ff0000
            """)
        #expect(load.config.palette[0] == ConfigColor(0x11_11_11))
        #expect(load.config.palette[1] == ConfigColor(0xFF_00_00))
    }

    @Test("a theme cannot name a theme, and is not warned about for trying")
    func themeCannotNestOrWarn() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.write(
            """
            theme = Something Else
            config-file = /etc/passwd
            background = #111111
            """, to: tree.resourcesThemes.appending(path: "Nord"))

        let load = try tree.load("theme = Nord")
        #expect(load.config.background == ConfigColor(0x11_11_11))
        #expect(load.config.theme == ConfigTheme("Nord"))
        #expect(load.diagnostics.isEmpty)
    }

    @Test("a bad key inside a theme is reported against the theme's own path")
    func themeDiagnostics() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        let file = tree.resourcesThemes.appending(path: "Nord")
        try tree.write("backgruond = #111111", to: file)

        let load = try tree.load("theme = Nord")
        #expect(load.diagnostics.count == 1)
        #expect(load.diagnostics[0].file == file.path)
        #expect(load.diagnostics[0].message == "unknown field")
    }

    @Test("a warning in the config is reported once, not once per pass")
    func diagnosticsAreNotDoubled() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.write("background = #111111", to: tree.resourcesThemes.appending(path: "Nord"))

        let load = try tree.load(
            """
            theme = Nord
            font-famly = Iosevka
            """)
        #expect(load.diagnostics.count == 1)
        #expect(load.diagnostics[0].key == "font-famly")
    }

    @Test("the appearance picks which half of a pair is loaded")
    func lightAndDark() throws {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.write("background = #ffffff", to: tree.resourcesThemes.appending(path: "Day"))
        try tree.write("background = #000000", to: tree.resourcesThemes.appending(path: "Night"))

        let config = "theme = light:Day,dark:Night"
        #expect(
            try tree.load(config, appearance: .light).config.background == ConfigColor(0xFF_FF_FF))
        #expect(try tree.load(config, appearance: .dark).config.background == ConfigColor(0))
    }

    @Test("an empty theme is an error rather than a reset")
    func emptyValue() throws {
        var config = Config()
        var diagnostics: [ConfigDiagnostic] = []
        config.apply(text: "theme =", path: "config", diagnostics: &diagnostics)
        #expect(config.theme == nil)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message == "value required")
    }
}
