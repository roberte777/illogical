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
