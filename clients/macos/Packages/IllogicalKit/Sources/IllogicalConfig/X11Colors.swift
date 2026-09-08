//  X11Colors.swift
//  `background = cornflower blue`, and the 780 other names that works for.
//
//  The table is `rgb.txt` from the X11 project, byte for byte the copy
//  libghostty embeds (`src/terminal/res/rgb.txt`), carried here rather than
//  transcribed into a Swift literal so that a future update is a file copy and
//  a diff of it means something. It is embedded in the binary at build time
//  (`.embedInCode` in Package.swift), so nothing is read from disk and there
//  is no `Bundle.module` to be missing from a test host.
//
//  Built on first use rather than at launch, and that is the point of the
//  laziness: a config file that names no colour by name — which is every theme
//  the app ships, all of them hex — never pays for the table at all.

import Foundation

enum X11Colors {
    /// The colour `name` stands for, matched ASCII case-insensitively.
    ///
    /// Case-insensitive because that is what libghostty's map does, and it is
    /// what makes `AliceBlue`, `aliceblue` and `alice blue` — the first two
    /// separate entries in the file, the third a third one — all resolve.
    static func color(named name: some StringProtocol) -> ConfigColor? {
        table[name.lowercased()]
    }

    /// Every entry, in file order, for the parity test to walk.
    static var names: [String] { entries.map(\.name) }

    private static let table: [String: ConfigColor] = {
        var result: [String: ConfigColor] = [:]
        result.reserveCapacity(entries.count)
        // Later duplicates lose, which is `StaticStringMap`'s rule too. The
        // file has none that disagree, so this only decides between spellings
        // of the same colour.
        for entry in entries where result[entry.name.lowercased()] == nil {
            result[entry.name.lowercased()] = entry.color
        }
        return result
    }()

    /// `rgb.txt`'s fixed columns: three right-aligned 3-character decimals at
    /// 0, 4 and 8, then the name from column 12 to the end of the line.
    ///
    /// The same shape libghostty parses, and as unforgiving: a line that does
    /// not fit is dropped rather than guessed at, because the only way one
    /// appears is a bad copy of the file — which the parity test would catch
    /// as a missing name.
    private static let entries: [(name: String, color: ConfigColor)] = {
        let text = String(decoding: PackageResources.rgb_txt, as: UTF8.self)
        var result: [(name: String, color: ConfigColor)] = []
        result.reserveCapacity(800)

        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard line.count > 12 else { continue }
            let bytes = Array(line.utf8)
            guard let r = UInt8(String(decoding: bytes[0..<3], as: UTF8.self).trimmedASCII),
                let g = UInt8(String(decoding: bytes[4..<7], as: UTF8.self).trimmedASCII),
                let b = UInt8(String(decoding: bytes[8..<11], as: UTF8.self).trimmedASCII)
            else { continue }
            let name = String(decoding: bytes[12...], as: UTF8.self).trimmedASCII
            guard !name.isEmpty else { continue }
            result.append((String(name), ConfigColor(r: r, g: g, b: b)))
        }

        return result
    }()
}
