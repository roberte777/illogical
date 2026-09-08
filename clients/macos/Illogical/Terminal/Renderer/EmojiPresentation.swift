//  EmojiPresentation.swift
//  Which codepoints are emoji unless you say otherwise.
//
//  The Unicode `Emoji_Presentation` property (UTS #51), generated from
//  `ucd/emoji/emoji-data.txt` in the uucode package ghostty pins — the same
//  data behind libghostty's `uucode.get(.is_emoji_presentation, cp)`. Unicode
//  emoji version 17.0. DO NOT EDIT BY HAND; regenerate if the pin moves.
//
//  This is the difference between a check mark and a check mark. U+2714 ✔ and
//  U+2764 ❤ are `Emoji_Presentation=No`: a font is supposed to draw them as
//  monochrome text glyphs that take the cell's foreground colour, and a green
//  ✔ from a test runner has to stay green. U+26A1 ⚡ and U+1F600 😀 are `Yes`
//  and are supposed to arrive in colour. Nothing about the codepoint's block
//  tells you which — they are interleaved — so it takes the table.
//
//  81 ranges covering 1219 codepoints.

import Foundation

enum EmojiPresentation {
    /// Sorted, non-overlapping, non-adjacent (lo, hi) pairs, inclusive.
    private static let ranges: [UInt32] = [
        0x231A, 0x231B, 0x23E9, 0x23EC, 0x23F0, 0x23F0, 0x23F3, 0x23F3, 0x25FD, 0x25FE,
        0x2614, 0x2615, 0x2648, 0x2653, 0x267F, 0x267F, 0x2693, 0x2693, 0x26A1, 0x26A1,
        0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26CE, 0x26CE, 0x26D4, 0x26D4,
        0x26EA, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26F5, 0x26FA, 0x26FA, 0x26FD, 0x26FD,
        0x2705, 0x2705, 0x270A, 0x270B, 0x2728, 0x2728, 0x274C, 0x274C, 0x274E, 0x274E,
        0x2753, 0x2755, 0x2757, 0x2757, 0x2795, 0x2797, 0x27B0, 0x27B0, 0x27BF, 0x27BF,
        0x2B1B, 0x2B1C, 0x2B50, 0x2B50, 0x2B55, 0x2B55, 0x1F004, 0x1F004, 0x1F0CF, 0x1F0CF,
        0x1F18E, 0x1F18E, 0x1F191, 0x1F19A, 0x1F1E6, 0x1F1FF, 0x1F201, 0x1F201, 0x1F21A, 0x1F21A,
        0x1F22F, 0x1F22F, 0x1F232, 0x1F236, 0x1F238, 0x1F23A, 0x1F250, 0x1F251, 0x1F300, 0x1F320,
        0x1F32D, 0x1F335, 0x1F337, 0x1F37C, 0x1F37E, 0x1F393, 0x1F3A0, 0x1F3CA, 0x1F3CF, 0x1F3D3,
        0x1F3E0, 0x1F3F0, 0x1F3F4, 0x1F3F4, 0x1F3F8, 0x1F43E, 0x1F440, 0x1F440, 0x1F442, 0x1F4FC,
        0x1F4FF, 0x1F53D, 0x1F54B, 0x1F54E, 0x1F550, 0x1F567, 0x1F57A, 0x1F57A, 0x1F595, 0x1F596,
        0x1F5A4, 0x1F5A4, 0x1F5FB, 0x1F64F, 0x1F680, 0x1F6C5, 0x1F6CC, 0x1F6CC, 0x1F6D0, 0x1F6D2,
        0x1F6D5, 0x1F6D8, 0x1F6DC, 0x1F6DF, 0x1F6EB, 0x1F6EC, 0x1F6F4, 0x1F6FC, 0x1F7E0, 0x1F7EB,
        0x1F7F0, 0x1F7F0, 0x1F90C, 0x1F93A, 0x1F93C, 0x1F945, 0x1F947, 0x1F9FF, 0x1FA70, 0x1FA7C,
        0x1FA80, 0x1FA8A, 0x1FA8E, 0x1FAC6, 0x1FAC8, 0x1FAC8, 0x1FACD, 0x1FADC, 0x1FADF, 0x1FAEA,
        0x1FAEF, 0x1FAF8,
    ]

    /// Whether this codepoint is drawn as emoji when nothing said otherwise.
    ///
    /// A binary search over the flat pair array, which is the shape
    /// `NerdFontConstraints` already uses for the same reason: a few hundred
    /// homogeneous literals cost the type checker nothing, where the same
    /// data as structs costs it a great deal.
    static func isEmojiPresentation(_ cp: UInt32) -> Bool {
        var low = 0
        var high = ranges.count / 2 - 1
        while low <= high {
            let mid = (low + high) / 2
            if cp < ranges[mid * 2] {
                if mid == 0 { return false }
                high = mid - 1
            } else if cp > ranges[mid * 2 + 1] {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }
}
