//  ThemePath.swift
//  Where `theme = <name>` looks, and in what order.
//
//  Ported from libghostty's `config/theme.zig`. Its two locations become three
//  here, and for the same reason this app reads two config files where Ghostty
//  reads one: the XDG directory is what a dotfiles repo carries between
//  machines, Application Support is what a Mac app owns, and the bundle is
//  what we shipped. First hit wins, so a theme of your own always beats one
//  of ours — which is what makes overriding a bundled theme a matter of
//  writing a file with the same name.
//
//  An absolute path skips all three. A relative one may not contain a path
//  separator at all: `theme = ../../etc/passwd` is refused rather than
//  resolved, and `theme = mine/dark` is a mistake worth naming rather than a
//  lookup that quietly fails.

import Foundation

public enum ThemePath {
    /// The directory name under each config location, and inside the bundle.
    public static let directoryName = "themes"

    /// Every directory to look in, in priority order.
    ///
    /// `resources` is the app bundle's own resources directory, or nil in a
    /// process that has none — a `swift test` run, or a command-line tool.
    /// Passed in rather than read from `Bundle.main` so that a test can point
    /// the search at a directory it wrote.
    public static func directories(
        bundleID: String?,
        resources: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var directories = [
            ConfigPath.xdg(environment: environment)
                .deletingLastPathComponent()
                .appending(path: directoryName)
        ]
        if let appSupport = ConfigPath.applicationSupport(
            bundleID: bundleID, environment: environment)
        {
            directories.append(
                appSupport.deletingLastPathComponent().appending(path: directoryName))
        }
        if let resources {
            directories.append(resources.appending(path: directoryName))
        }
        return directories
    }

    /// What was found for `name`, or what to say about not finding it.
    public enum Resolution: Equatable {
        /// A regular file to read.
        case file(URL)
        /// Nothing to read, and why — one diagnostic per path tried, which is
        /// libghostty's behaviour and the right one: "not found" without the
        /// list of places looked is the least useful message a config file
        /// can produce.
        case missing([ConfigDiagnostic])
    }

    /// Find the file `name` refers to.
    public static func resolve(
        _ name: String,
        bundleID: String?,
        resources: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Resolution {
        if name.hasPrefix("/") {
            return regularFile(URL(fileURLWithPath: name), name: name)
                ?? .missing([
                    ConfigDiagnostic(
                        key: "theme", message: "failed to load theme from the path \"\(name)\"")
                ])
        }

        guard !name.contains("/") else {
            return .missing([
                ConfigDiagnostic(
                    key: "theme",
                    message:
                        "theme \"\(name)\" cannot include path separators unless it is an absolute path"
                )
            ])
        }

        let directories = directories(
            bundleID: bundleID, resources: resources, environment: environment)
        for directory in directories {
            let candidate = directory.appending(path: name)
            // `regularFile` returns nil both for "not there" and for "there
            // but not a file". libghostty stops at the second with a
            // diagnostic; we carry on to the next location, because a
            // *directory* called Nord in one place is no reason not to use the
            // theme called Nord in another.
            if let found = regularFile(candidate, name: name) { return found }
        }

        return .missing(
            directories.map { directory in
                ConfigDiagnostic(
                    key: "theme",
                    message:
                        "theme \"\(name)\" not found, tried path \"\(directory.appending(path: name).path)\""
                )
            })
    }

    /// `.file(url)` when something readable and regular is there, else nil.
    private static func regularFile(_ url: URL, name: String) -> Resolution? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        guard !isDirectory.boolValue else { return nil }
        return .file(url)
    }
}
