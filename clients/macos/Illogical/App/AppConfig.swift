//  AppConfig.swift
//  The config file, read once at launch, for everything that reads it.
//
//  Loading is explicit — `IllogicalApp.init()` calls `load()` — rather than a
//  lazy `static let` that reads on first use, and the difference is not
//  style. A lazy global would make the first pane to ask for a font size read
//  the config file, which means every *test* process that builds a surface
//  reads the developer's own `~/.config/illogical/config` and, finding none,
//  creates one under whatever bundle identifier the test host happens to have.
//  A process that has not called `load()` gets the defaults, and that is the
//  correct answer for all of them.

import Foundation
import IllogicalConfig
import os

enum AppConfig {
    /// Read from render threads — a pane's font comes from here — and written
    /// once before any of them exist. The lock is for the memory model rather
    /// than for contention.
    private static let storage = OSAllocatedUnfairLock(initialState: Config())

    /// `os.Logger` and not only `Trace`, because these are the one kind of
    /// message that has to reach somebody who is not debugging the app. A
    /// misspelled key is invisible by construction — the option simply does
    /// not take effect — so the warning is all there is, and `Trace` is off
    /// unless `ILLOGICAL_TRACE` is set. Surfacing them in the window itself is
    /// the follow-up (#39); Console.app is where they are until then.
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.illogical.Illogical",
        category: "config")

    /// What the config file says. Defaults on any process that has not called
    /// `load()`.
    static var current: Config { storage.withLock { $0 } }

    /// The font half of it, in the renderer's own vocabulary.
    ///
    /// The one place the two line up, and the reason `Renderer/` does not
    /// import the config package at all: a grid is built from a `FontConfig`,
    /// so a test builds one directly instead of writing a config file to get
    /// at the renderer.
    static var font: FontConfig {
        let config = current
        return FontConfig(
            regular: config.fontFamily,
            bold: config.fontFamilyBold,
            italic: config.fontFamilyItalic,
            boldItalic: config.fontFamilyBoldItalic,
            pointSize: config.fontSize)
    }

    /// The renderer half of it, the same way `font` is the font half: the
    /// `Renderer/` directory does not import the config package, so this is
    /// the one place the two vocabularies meet.
    ///
    /// Read when a surface is built, so a config change needs the surface
    /// rebuilt to take effect — the same rule the font follows, and for the
    /// same reason (#39).
    static var renderer: RendererConfig {
        var renderer = RendererConfig()
        renderer.backgroundOpacity = current.backgroundOpacity
        return renderer
    }

    /// Whether the window has anything to be translucent *over*.
    ///
    /// Both halves, because either alone is a no-op: blur with an opaque
    /// terminal has nothing behind it to blur, and a translucent terminal in
    /// an opaque window shows the window's own background rather than the
    /// desktop. `WindowChrome` reads this to decide whether the window stops
    /// being opaque at all.
    static var isTranslucent: Bool { current.backgroundOpacity < 1 }

    /// Read the config files, create one if this machine has none, and say
    /// what happened.
    ///
    /// On the launch path (G7), and deliberately: two `stat`s and a small read
    /// of a file that is almost always in the page cache, against a font grid
    /// built a few milliseconds later that cannot be built twice. Only the
    /// first launch on a machine writes anything, and it writes one 2 KB file.
    @discardableResult
    static func load() -> ConfigLoad {
        let result = Config.loadDefaults(bundleID: Bundle.main.bundleIdentifier)
        storage.withLock { $0 = result.config }

        for source in result.sources {
            logger.info("read \(source.path, privacy: .public)")
            Trace.log("config read \(source.path)")
        }
        if let created = result.created {
            logger.info("created \(created.path, privacy: .public)")
            Trace.log("config created \(created.path)")
        }
        for diagnostic in result.diagnostics {
            // `.public` throughout: every one of these is a path the person
            // chose and a key they typed, and a log line that redacts the
            // misspelling is no use to anybody.
            logger.warning("\(diagnostic.description, privacy: .public)")
            Trace.log("config warning \(diagnostic.description)")
        }

        return result
    }
}
