//  RenderCell.swift
//  The flat, per-cell form the renderer works from.
//
//  libghostty's render state hands out cell data through an iterator with one
//  C call per field. That is fine for the handful of dirty rows a normal
//  frame touches, but the renderer wants random access (the shaper looks at
//  neighbours; constraint width looks two cells ahead), so we pull each dirty
//  row into a flat array once and then work from that.
//
//  Deliberately a fixed-size struct with no references: rows are extracted
//  into a buffer that is reused every frame, so a busy terminal does no
//  allocation at all in the per-frame path.

import Foundation

/// An RGB colour that may be absent, without paying for an Optional's extra
/// word per cell.
struct PackedRGB: Equatable {
    var r: UInt8 = 0
    var g: UInt8 = 0
    var b: UInt8 = 0
    var present: Bool = false

    static let none = PackedRGB()

    init() {}

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.present = true
    }

    var value: (r: UInt8, g: UInt8, b: UInt8)? {
        present ? (r, g, b) : nil
    }
}

/// How a cell relates to wide characters.
enum CellWide: UInt8 {
    case narrow = 0
    case wide = 1
    /// The second half of a wide character. Never rendered.
    case spacerTail = 2
    /// Padding at the end of a soft-wrapped line before a wide character.
    case spacerHead = 3
}

/// SGR attributes that affect rendering.
struct CellFlags: OptionSet, Hashable {
    let rawValue: UInt16

    static let bold = CellFlags(rawValue: 1 << 0)
    static let italic = CellFlags(rawValue: 1 << 1)
    static let faint = CellFlags(rawValue: 1 << 2)
    static let blink = CellFlags(rawValue: 1 << 3)
    static let inverse = CellFlags(rawValue: 1 << 4)
    static let invisible = CellFlags(rawValue: 1 << 5)
    static let strikethrough = CellFlags(rawValue: 1 << 6)
    static let overline = CellFlags(rawValue: 1 << 7)

    /// The font style implied by these flags.
    var fontStyle: FontStyle {
        if contains(.bold) { return contains(.italic) ? .boldItalic : .bold }
        if contains(.italic) { return .italic }
        return .regular
    }
}

/// Underline styles, matching GHOSTTY_SGR_UNDERLINE_*.
enum CellUnderline: UInt8 {
    case none = 0
    case single = 1
    case double = 2
    case curly = 3
    case dotted = 4
    case dashed = 5

    /// The sprite that draws this style.
    var sprite: Sprite? {
        switch self {
        case .none: return nil
        case .single: return .underline
        case .double: return .underlineDouble
        case .curly: return .underlineCurly
        case .dotted: return .underlineDotted
        case .dashed: return .underlineDashed
        }
    }
}

/// One cell, flattened.
struct RenderCell {
    /// The base codepoint. 0 means the cell has no text.
    var codepoint: UInt32 = 0
    /// Additional grapheme codepoints, as a range into the row's scratch
    /// buffer. Zero length for the overwhelmingly common single-codepoint
    /// case, which costs nothing.
    var graphemeOffset: UInt32 = 0
    var graphemeLen: UInt32 = 0

    var wide: CellWide = .narrow
    var flags: CellFlags = []
    var underline: CellUnderline = .none

    /// Resolved by libghostty: palette indices are already looked up, and the
    /// background flattens the content-tag and style sources.
    var fg: PackedRGB = .none
    var bg: PackedRGB = .none
    var underlineColor: PackedRGB = .none

    var hasText: Bool = false
    var hasStyling: Bool = false
    var selected: Bool = false

    /// True when the cell has nothing to draw and no background of its own.
    var isEmpty: Bool { !hasText && !hasStyling && !bg.present }

    /// Cells this character occupies in the grid.
    var gridWidth: UInt8 { wide == .wide ? 2 : 1 }

    /// Whether two cells may share a shaping run. Background colour is
    /// excluded: the background is painted separately, so a run may span a
    /// change in it without any visual difference. Everything else that
    /// affects glyph selection or colour must match.
    func shapingEqual(_ other: RenderCell) -> Bool {
        flags == other.flags
            && underline == other.underline
            && fg == other.fg
            && underlineColor == other.underlineColor
    }
}

/// One row of extracted cells plus its grapheme scratch.
struct RenderRow {
    var cells: [RenderCell] = []
    /// Extra grapheme codepoints for cells in this row, referenced by
    /// `RenderCell.graphemeOffset`.
    var graphemes: [UInt32] = []
    /// Row-local selection range, inclusive, if the row intersects one.
    var selection: (start: UInt16, end: UInt16)? = nil

    mutating func reset(columns: Int) {
        if cells.count != columns {
            cells = [RenderCell](repeating: RenderCell(), count: columns)
        } else {
            for i in cells.indices { cells[i] = RenderCell() }
        }
        graphemes.removeAll(keepingCapacity: true)
        selection = nil
    }
}
