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

import AppKit
import Foundation
import IllogicalConfig
import SwiftUI
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
        let config = current
        var renderer = RendererConfig()
        renderer.backgroundOpacity = config.backgroundOpacity
        renderer.minimumContrast = Float(config.minimumContrast)
        renderer.selectionBackground = config.selectionBackground?.render
        renderer.selectionForeground = config.selectionForeground?.render
        renderer.cursorText = config.cursorText?.render

        // Only the two cell-relative spellings of `cursor-color` reach the
        // renderer. A fixed one is set on the terminal instead — see
        // `TerminalColors` — and passing it here as well would put it ahead of
        // the program's own OSC 12, which is the one thing that must outrank
        // it.
        switch config.cursorColor {
        case .cellForeground, .cellBackground:
            renderer.cursorColor = config.cursorColor?.render
        case .color, nil:
            break
        }
        return renderer
    }

    /// Which half of `theme = light:x,dark:y` applies right now.
    ///
    /// The *desktop's* setting, and deliberately not
    /// `NSApp.effectiveAppearance`: this app sets its own appearance from the
    /// theme (`windowAppearance`), so asking AppKit what appearance we are in
    /// would sometimes be asking what we told it a moment ago. `light:x,dark:y`
    /// has to follow the machine, not itself.
    ///
    /// Absent means light, which is the convention: macOS writes this default
    /// only in dark mode.
    ///
    /// Read at launch, so switching the system between light and dark needs
    /// the app restarted to take effect -- the same rule the font and the
    /// colours follow, and the same follow-up (#39).
    static var systemAppearance: ConfigAppearance {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }

    /// The appearance AppKit should draw everything we do not paint in.
    ///
    /// Nil is never returned: the point of this is to *stop* deferring to the
    /// system when the theme disagrees with it, and `window-theme = system` is
    /// spelled by resolving the system's own appearance rather than by handing
    /// AppKit a nil and hoping.
    static var windowAppearance: NSAppearance? {
        NSAppearance(named: resolvedAppearance == .light ? .aqua : .darkAqua)
    }

    /// The same answer, for SwiftUI. Both are needed: `WindowChrome` sets the
    /// `NSAppearance` so that AppKit's own title bar draws correctly, and
    /// SwiftUI's `preferredColorScheme` outranks it inside the hosted view --
    /// so a window that set only the first had light traffic lights above
    /// dark buttons.
    static var windowColorScheme: ColorScheme {
        resolvedAppearance == .light ? .light : .dark
    }

    private static var resolvedAppearance: ConfigAppearance {
        let config = current
        return config.windowTheme.appearance(
            background: config.background,
            system: systemAppearance,
            conditional: config.theme?.isConditional ?? false)
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
    /// `arguments` defaults to this process's, minus its own path. Injectable
    /// so a test can drive the seam without `CommandLine`, which is global,
    /// unsettable, and full of whatever the test runner put there.
    @discardableResult
    static func load(
        arguments: [String] = Array(CommandLine.arguments.dropFirst())
    )
        -> ConfigLoad
    {
        let result = Config.loadDefaults(
            bundleID: Bundle.main.bundleIdentifier, appearance: systemAppearance,
            arguments: arguments)
        storage.withLock { $0 = result.config }

        // The chrome, from the same colours. Here rather than lazily inside
        // `Palette` for the reason loading is explicit at all: a lazy read
        // would have the first SwiftUI body to ask for a divider colour
        // resolve a 256-entry palette, on whatever thread and in whatever
        // process happened to ask first.
        let colors = TerminalColors.from(result.config)
        Palette.adopt(
            Palette.Source(
                background: result.config.background,
                foreground: result.config.foreground,
                green: ConfigColor(
                    r: colors.palette[2].r, g: colors.palette[2].g,
                    b: colors.palette[2].b),
                blue: ConfigColor(
                    r: colors.palette[4].r, g: colors.palette[4].g,
                    b: colors.palette[4].b)))

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

extension ConfigTerminalColor {
    /// The same value in the renderer's vocabulary.
    ///
    /// Two enums with the same three cases, and they stay two on purpose:
    /// `Renderer/` does not import the config package, so that a font grid or
    /// a selection colour can be built in a test without a config file
    /// anywhere near it.
    var render: RenderColor {
        switch self {
        case .color(let c): return .color(r: c.r, g: c.g, b: c.b)
        case .cellForeground: return .cellForeground
        case .cellBackground: return .cellBackground
        }
    }
}
