//  ConfigPath.swift
//  Where the config file lives.
//
//  libghostty's two locations, in its order (`config/file_load.zig`):
//
//      $XDG_CONFIG_HOME/illogical/config          (~/.config/illogical/config)
//      ~/Library/Application Support/<bundle id>/config
//
//  Both are read, XDG first, so the app-specific file wins where they
//  disagree. Two locations rather than one because they answer different
//  questions: the XDG file is the one a dotfiles repo carries between
//  machines, and the Application Support file is the one a Mac app is
//  supposed to own and the one a settings UI would write.
//
//  The name is `config`, with no extension. Ghostty 1.3 moved to
//  `config.ghostty` so that editors can key syntax highlighting off the
//  extension; we ship no editor plugin, so the extension would buy nothing
//  and cost a file name nobody guesses.

import Foundation

public enum ConfigPath {
    /// Our directory under the XDG config home, and the file name in both
    /// locations.
    public static let directoryName = "illogical"
    public static let fileName = "config"

    /// Names the one config file to read, in place of both defaults.
    ///
    /// The same seam as `ILLOGICAL_SOCK` and `ILLOGICAL_DAEMON`, and there for
    /// the same reason: nothing in a developer's tree, a test or a bench
    /// script should ever read — or create — the config file they actually
    /// use. Set to empty to read nothing at all.
    public static let overrideVariable = "ILLOGICAL_CONFIG"

    /// `$XDG_CONFIG_HOME/illogical/config`, falling back to
    /// `~/.config/illogical/config`.
    public static func xdg(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = home(environment).appending(path: ".config")
        }
        return base.appending(path: directoryName).appending(path: fileName)
    }

    /// `~/Library/Application Support/<bundle id>/config`, or nil in a process
    /// with no bundle identifier — a `swift test` run, or a command-line tool.
    ///
    /// Built from `$HOME` rather than asked of `FileManager`, which is the
    /// same choice `Transport.controlPath` makes and for the same reason: it
    /// is the input a test can supply. The two agree — the app is not
    /// sandboxed (`Illogical.entitlements`) — and they would still agree if it
    /// were, since a sandbox rewrites `$HOME` to the container.
    public static func applicationSupport(
        bundleID: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return
            home(environment)
            .appending(path: "Library/Application Support")
            .appending(path: bundleID)
            .appending(path: fileName)
    }

    /// Every file to read, in the order to read them. Later files win.
    ///
    /// Note that "win" is per *line*, not per file: the files are applied to
    /// one config in sequence, so a `font-family` in Application Support
    /// appends to the list the XDG file started rather than replacing it.
    /// That is libghostty's behaviour, and it follows from `font-family`
    /// repeating at all — a second file is not different from a second line.
    /// `font-family = ""` first is how you mean "replace".
    public static func defaults(
        bundleID: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let override = environment[overrideVariable] {
            return override.isEmpty ? [] : [URL(fileURLWithPath: override)]
        }
        var files = [xdg(environment: environment)]
        if let appSupport = applicationSupport(bundleID: bundleID, environment: environment) {
            files.append(appSupport)
        }
        return files
    }

    /// Where a config file should be *created* when there is none: the one a
    /// Mac app owns, falling back to XDG for a process that has no bundle.
    public static func preferred(
        bundleID: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        applicationSupport(bundleID: bundleID, environment: environment)
            ?? xdg(environment: environment)
    }

    /// `$HOME`, and the passwd entry only if there is none.
    ///
    /// This way round because everything else in the app that resolves a path
    /// reads `$HOME` — the daemon's `getenv("HOME")`, the ssh control path —
    /// and a config file found somewhere else than the socket would be a
    /// confusing thing to debug.
    private static func home(_ environment: [String: String]) -> URL {
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
