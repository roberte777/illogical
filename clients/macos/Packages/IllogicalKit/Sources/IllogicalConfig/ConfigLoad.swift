//  ConfigLoad.swift
//  Reading the config files, and what reading them produced.
//
//  Every file is optional and every failure is a warning. A missing file is
//  the normal case — most people never write one — and a file that cannot be
//  read is still not a reason to refuse to open a terminal, since the terminal
//  is usually how the file gets fixed. libghostty makes the same call:
//  `loadOptionalFile` swallows everything and logs.

import Foundation

/// The config the files add up to, and everything that happened on the way.
public struct ConfigLoad: Equatable, Sendable {
    /// Finalized and ready to use. Defaults, if no file said otherwise.
    public var config: Config

    /// Warnings, in the order they were found. Nothing here stops anything;
    /// the app logs them and carries on.
    public var diagnostics: [ConfigDiagnostic]

    /// The files that existed and were read, in the order they were read.
    /// Empty means this machine has no config file — which is what decides
    /// whether a template gets written.
    public var sources: [URL]

    /// The template file this launch created, if it created one. Worth a log
    /// line: it is the only announcement a person gets that the file now
    /// exists.
    public var created: URL?

    public init(
        config: Config,
        diagnostics: [ConfigDiagnostic] = [],
        sources: [URL] = [],
        created: URL? = nil
    ) {
        self.config = config
        self.diagnostics = diagnostics
        self.sources = sources
        self.created = created
    }
}

extension Config {
    /// Everything the app does with config at launch: find the files, read
    /// them, and write a template when this machine has none.
    ///
    /// libghostty's `loadDefaultFiles`, and one function for the same reason
    /// it is one function there — the template is written *because* nothing
    /// was loaded, so the decision cannot be made anywhere but here.
    ///
    /// Nothing is created when `ILLOGICAL_CONFIG` names a file. Somebody who
    /// pointed us at a path meant that path; a template appearing at the
    /// default location instead would be a file they did not ask for in a
    /// place they are not looking.
    public static func loadDefaults(
        bundleID: String?,
        resources: URL? = Bundle.main.resourceURL,
        appearance: ConfigAppearance = .dark,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ConfigLoad {
        let files = ConfigPath.defaults(bundleID: bundleID, environment: environment)
        var result = load(
            files: files, bundleID: bundleID, resources: resources, appearance: appearance,
            environment: environment)
        guard result.sources.isEmpty, environment[ConfigPath.overrideVariable] == nil else {
            return result
        }

        let file = ConfigPath.preferred(bundleID: bundleID, environment: environment)
        do {
            if try ConfigTemplate.write(to: file) { result.created = file }
        } catch {
            // A warning and nothing more. Not being able to create a file
            // nobody asked for is not a reason to hold up a launch.
            result.diagnostics.append(
                ConfigDiagnostic(
                    file: file.path,
                    message: "could not create it: \(error.localizedDescription)"))
        }
        return result
    }

    /// Read `files` in order into one config.
    ///
    /// One config, not one per file: a later file's `font-family` appends to
    /// the earlier file's list rather than replacing it, exactly as a second
    /// line in one file would. See `ConfigPath.defaults`.
    ///
    /// Then, if any of them named a `theme`, the whole lot is applied a second
    /// time on top of it. See `applying(theme:)`.
    public static func load(
        files: [URL],
        bundleID: String? = nil,
        resources: URL? = nil,
        appearance: ConfigAppearance = .dark,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ConfigLoad {
        var config = Config()
        var diagnostics: [ConfigDiagnostic] = []
        var sources: [URL] = []
        // What was applied, in order, so a theme can be slid underneath it.
        // Kept here rather than on `Config` deliberately: two configs holding
        // the same colours have to compare equal however they were arrived
        // at, and a record of the lines that produced them would break that.
        var replay: [(entry: ConfigEntry, path: String)] = []

        for file in files {
            guard let text = read(file, diagnostics: &diagnostics) else { continue }
            sources.append(file)
            for entry in ConfigSyntax.entries(of: text) {
                config.apply(entry, path: file.path, diagnostics: &diagnostics)
                replay.append((entry, file.path))
            }
        }

        if let theme = config.theme {
            let reloaded = applying(
                theme: theme, replay: replay, bundleID: bundleID, resources: resources,
                appearance: appearance, environment: environment)
            config = reloaded.config
            // The replay produced this run's diagnostics a second time, so
            // the first pass's are dropped rather than doubled. Only the
            // file-level ones -- a config file that could not be read at all
            // -- survive from it, and those are what `diagnostics` holds
            // before any entry is applied.
            diagnostics = read(files: files) + reloaded.diagnostics
        }

        config.finalize()
        return ConfigLoad(config: config, diagnostics: diagnostics, sources: sources)
    }

    /// Load `theme` and put the config that named it back on top.
    ///
    /// libghostty's `loadTheme`, and the same dance for the same two reasons.
    /// A theme is an ordinary config file, so the only way for `background =
    /// #ff0000` in your own config to beat the theme's background is for the
    /// theme to be applied *first* -- and the option that named it can appear
    /// anywhere in the file, including after the colours it is supposed to
    /// lose to. Applying entries one at a time cannot do that. So the config
    /// is thrown away and rebuilt: defaults, then the theme, then every line
    /// the files held, in order.
    ///
    /// Which means every diagnostic is produced twice over a run, and the
    /// second set is the one that gets reported. They are identical -- the
    /// same entries against the same defaults -- so which set is dropped is
    /// arbitrary; that it is exactly one of them is not.
    private static func applying(
        theme: ConfigTheme,
        replay: [(entry: ConfigEntry, path: String)],
        bundleID: String?,
        resources: URL?,
        appearance: ConfigAppearance,
        environment: [String: String]
    ) -> (config: Config, diagnostics: [ConfigDiagnostic]) {
        var config = Config()
        var diagnostics: [ConfigDiagnostic] = []

        let name = theme.expandingHome(home(environment)).name(for: appearance)
        switch ThemePath.resolve(
            name, bundleID: bundleID, resources: resources, environment: environment)
        {
        case .missing(let reasons):
            diagnostics.append(contentsOf: reasons)
        case .file(let file):
            var fileDiagnostics: [ConfigDiagnostic] = []
            if let text = read(file, diagnostics: &fileDiagnostics) {
                for entry in ConfigSyntax.entries(of: text) {
                    // A theme cannot name a theme. libghostty ignores this
                    // silently rather than warning, and silence is right:
                    // the file is not the user's, so a warning would be about
                    // somebody else's mistake in a file they cannot edit.
                    guard entry.key != "theme", entry.key != "config-file" else { continue }
                    config.apply(entry, path: file.path, diagnostics: &diagnostics)
                }
            }
            diagnostics.append(contentsOf: fileDiagnostics)
        }

        for step in replay {
            config.apply(step.entry, path: step.path, diagnostics: &diagnostics)
        }
        return (config, diagnostics)
    }

    /// The diagnostics reading `files` produces on its own, without applying
    /// anything in them -- a file that is a directory, or that cannot be
    /// opened. Cheap: the successful case is a read of a file already in the
    /// page cache, and this only runs when a theme was named.
    private static func read(files: [URL]) -> [ConfigDiagnostic] {
        var diagnostics: [ConfigDiagnostic] = []
        for file in files { _ = read(file, diagnostics: &diagnostics) }
        return diagnostics
    }

    /// `$HOME`, for expanding a `~` in a theme path. The same rule
    /// `ConfigPath` follows, and duplicated rather than shared because
    /// `ConfigPath.home` is private to the question of where a config lives.
    private static func home(_ environment: [String: String]) -> URL {
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The contents of `file`, or nil when there is nothing to read.
    ///
    /// Nil for a file that is not there, silently: that is the common case,
    /// not a problem. Nil *with* a diagnostic for anything else — a directory
    /// where a file should be, a file we lack permission to open — because
    /// those are all cases where somebody meant to configure something and it
    /// did not happen.
    private static func read(_ file: URL, diagnostics: inout [ConfigDiagnostic]) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            diagnostics.append(
                ConfigDiagnostic(file: file.path, message: "not reading it: it is a directory"))
            return nil
        }

        do {
            // Lenient decoding: an invalid byte becomes U+FFFD rather than
            // failing the whole file. A config file with one bad byte in a
            // comment should not read as no config file at all, and the
            // replacement character will make its way into a diagnostic if it
            // landed anywhere that matters.
            return String(decoding: try Data(contentsOf: file), as: UTF8.self)
        } catch {
            diagnostics.append(
                ConfigDiagnostic(
                    file: file.path,
                    message: "not reading it: \(error.localizedDescription)"))
            return nil
        }
    }
}
