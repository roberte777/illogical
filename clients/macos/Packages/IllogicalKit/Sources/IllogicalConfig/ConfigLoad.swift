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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ConfigLoad {
        let files = ConfigPath.defaults(bundleID: bundleID, environment: environment)
        var result = load(files: files)
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
    public static func load(files: [URL]) -> ConfigLoad {
        var config = Config()
        var diagnostics: [ConfigDiagnostic] = []
        var sources: [URL] = []

        for file in files {
            guard let text = read(file, diagnostics: &diagnostics) else { continue }
            sources.append(file)
            config.apply(text: text, path: file.path, diagnostics: &diagnostics)
        }

        config.finalize()
        return ConfigLoad(config: config, diagnostics: diagnostics, sources: sources)
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
