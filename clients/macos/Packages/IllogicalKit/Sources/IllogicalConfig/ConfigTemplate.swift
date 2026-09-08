//  ConfigTemplate.swift
//  The commented file written when a machine has none.
//
//  Ghostty does this (`writeConfigTemplate`), and it is worth copying for a
//  reason that has nothing to do with familiarity: a config file that does not
//  exist is undiscoverable. There is no menu item that reveals it, no error
//  that mentions it, and the path is three directories deep. A file that is
//  already there — even one that sets nothing — turns "where do I put this"
//  into "open this file".
//
//  It sets nothing on purpose. Every line is a comment, so deleting the file
//  and losing it changes no behaviour, and nothing in it can drift out of
//  agreement with the defaults in `Config`.

import Foundation

public enum ConfigTemplate {
    /// The file's contents, with `path` written into the header so that a
    /// person who finds it in an editor knows where on disk they are.
    public static func text(path: String) -> String {
        """
        # This is the configuration file for Illogical.
        #
        # It was created at
        #
        #   \(path)
        #
        # because there was no config file on this machine. It sets nothing:
        # the app ships with defaults for everything, and an option is only
        # worth writing here if you want something other than the default.
        #
        # The syntax and the option names are Ghostty's.

        # Syntax
        # ======
        # # Key and value, separated by an equals sign. Spacing around the
        # # equals sign does not matter, so these are all the same:
        # key=value
        # key= value
        # key =value
        # key = value
        #
        # # A line beginning with # is a comment. A # cannot go after a value:
        # # it would be part of it. This sets a value of "#123abc":
        # key = #123abc
        #
        # # An empty value resets a key to its default:
        # key =
        #
        # # Quotes around a value are stripped, which is how a value keeps a
        # # leading or trailing space.
        # key = " value "

        # Fonts
        # =====
        # # The font terminals are drawn in. Defaults to the one the app
        # # ships, which is JetBrains Mono.
        # font-family = Berkeley Mono
        #
        # # Repeat it to add fallbacks. The first family that has the
        # # character wins; your system's own fallback chain is asked only
        # # after every one of these has missed.
        # font-family = Berkeley Mono
        # font-family = Noto Sans CJK
        #
        # # Because repeating appends, clearing the list needs an empty value
        # # of its own:
        # font-family = ""
        # font-family = "My Favorite Font"
        #
        # # Styles are looked for inside the family above unless you name one
        # # here, and a family that has no italic gets a synthesized one
        # # rather than another family's. That is deliberate: bold text drawn
        # # from a different typeface than the text around it looks wrong.
        # font-family-bold = Berkeley Mono Bold
        # font-family-italic = Berkeley Mono Oblique
        # font-family-bold-italic = Berkeley Mono Bold Oblique
        #
        # # Points, and fractional sizes are allowed: the cell is measured in
        # # pixels, so 13.5 on a 2x display is a real 27px cell.
        # font-size = 13

        # Window
        # ======
        # # How opaque the terminal is, from 0 to 1. Only the terminal: the
        # # toolbar, the tabs and the breadcrumb above them stay solid at any
        # # value, so the window is still something you can aim at.
        # background-opacity = 0.9
        #
        # # Blur what shows through, in pixels. Does nothing unless you also
        # # set an opacity below 1 -- with an opaque terminal there is nothing
        # # behind it to blur.
        # #
        # # true is 20, which is the radius Ghostty picks for the same word,
        # # or write the number you want:
        # background-blur = true
        # background-blur = 30

        # Colours
        # =======
        # # A colour is hex with or without the #, an X11 name, or
        # # XParseColor's rgb: and rgbi: forms. These are all the same red:
        # background = #ff0000
        # background = ff0000
        # background = f00
        # background = red
        # background = rgb:ff/00/00
        # background = rgbi:1/0/0
        #
        # # The terminal's own two, for cells that carry no colour.
        # background = #1e1e2e
        # foreground = #cdd6f4
        #
        # # The 16 ANSI colours, and any of the other 240. Repeat the key; the
        # # index may be decimal, or 0x, 0o or 0b prefixed.
        # palette = 0=#45475a
        # palette = 1=#f38ba8
        # palette = 0xF=#a6adc8
        #
        # # Derive 16-255 from the 16 above rather than using xterm's cube, so
        # # that a palette of your own stays in keeping with itself. Off by
        # # default: a lot of software assumes it knows what xterm's indices
        # # are, and moving them makes that software unreadable.
        # palette-generate = true
        #
        # # The cursor's block, and the character underneath it. Unset, the
        # # cursor is the foreground colour and the character under it is the
        # # background, which reads as a knockout.
        # cursor-color = #f5e0dc
        # cursor-text = #1e1e2e
        #
        # # The selection. Unset, it inverts the terminal's two colours.
        # selection-background = #f5e0dc
        # selection-foreground = #1e1e2e
        #
        # # Any of those four can be cell-foreground or cell-background
        # # instead, which is the cell's own colour rather than a fixed one --
        # # a selection that keeps each token's colour instead of flattening
        # # them, or a cursor that inverts whatever it is standing on.
        # cursor-color = cell-foreground
        # cursor-text = cell-background
        #
        # # Force a WCAG contrast ratio between text and its own background,
        # # 1 through 21. 1 is off, and off is the default: this overrides the
        # # colour a program asked for. 1.1 avoids invisible text; 3 or more
        # # pushes text towards black and white.
        # minimum-contrast = 1.1

        """
    }

    /// Write the template at `file`, and return whether it was written.
    ///
    /// False, not an error, when something is already there. This runs at
    /// every launch that finds no config, and the check that got us here and
    /// the write are not one operation — `.withoutOverwriting` is what makes
    /// that race lose safely rather than truncate a file somebody just
    /// created.
    @discardableResult
    public static func write(to file: URL) throws -> Bool {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try Data(text(path: file.path).utf8).write(to: file, options: .withoutOverwriting)
            return true
        } catch CocoaError.fileWriteFileExists {
            return false
        }
    }
}
