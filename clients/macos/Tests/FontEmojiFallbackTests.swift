//  FontEmojiFallbackTests.swift
//  Apple Color Emoji, pinned rather than discovered.
//
//  The system cascade already finds *an* emoji font, so nothing here is
//  about emoji appearing at all — they did before. It is about *which* font
//  answers. libghostty pins the name for a stated reason: "in case people add
//  other emoji fonts to their system, we always want to prefer the official
//  one." A machine with a third-party emoji font installed is the case that
//  breaks, and it is not one a test on this machine can construct — so what
//  is asserted instead is the property that makes it impossible: the official
//  face is in the grid's own list, which is searched to exhaustion before the
//  cascade is consulted at all.

import CoreText
import XCTest

final class FontEmojiFallbackTests: XCTestCase {
    private static let pointSize: Double = 13
    private static let scale: Double = 2

    private func grid(family: String? = nil) -> FontGrid {
        FontGridSet.grid(family: family, pointSize: Self.pointSize, scale: Self.scale)
    }

    private func names(_ grid: FontGrid, _ style: FontStyle) -> [String] {
        grid.faces(style: style).map { CTFontCopyFamilyName($0.font) as String }
    }

    private func family(_ grid: FontGrid, _ index: FontIndex) throws -> String {
        CTFontCopyFamilyName(try XCTUnwrap(grid.face(index)).font) as String
    }

    /// A grimacing face: emoji-only, in no text font, and not a codepoint
    /// with a text presentation to argue about.
    private static let emojiOnly: UInt32 = 0x1F600
    /// Warning sign: in the font we ship and in Apple Color Emoji, and
    /// `Emoji_Presentation=No` — so it is text unless somebody says
    /// otherwise.
    private static let contestedText: UInt32 = 0x26A0
    /// High voltage, its next-door neighbour: in the same two faces, and
    /// `Emoji_Presentation=Yes`. The two differ in nothing a font can see,
    /// which is why the answer has to come from the Unicode table.
    private static let contestedEmoji: UInt32 = 0x26A1
    /// Heavy check mark: in Apple Color Emoji and in neither face we ship,
    /// and text by default. The green ✔ a test runner prints.
    private static let checkMark: UInt32 = 0x2714

    /// The face is in the grid rather than left to the cascade. This is the
    /// whole change: a list the grid owns is searched before the system is
    /// asked anything.
    func testTheEmojiFaceIsInEveryStyleList() throws {
        let grid = self.grid()
        for style in FontStyle.allCases {
            XCTAssertTrue(
                names(grid, style).contains("Apple Color Emoji"), "style \(style)")
        }
    }

    /// Behind everything, including the symbols. A codepoint both carry
    /// should come from the symbols face, which is libghostty's order.
    func testTheEmojiFaceIsLast() throws {
        let grid = self.grid()
        for style in FontStyle.allCases {
            XCTAssertEqual(names(grid, style).last, "Apple Color Emoji", "style \(style)")
        }
    }

    /// One slot shared by all four styles. Emoji have no bold or italic, and
    /// a slot per style would pack the same glyph into the atlas four times.
    func testTheEmojiFaceIsOneSlotSharedByEveryStyle() throws {
        let grid = self.grid()
        let regular = try XCTUnwrap(
            grid.index(codepoint: Self.emojiOnly, style: .regular, presentation: .emoji))
        for style in FontStyle.allCases {
            XCTAssertEqual(
                grid.index(codepoint: Self.emojiOnly, style: style, presentation: .emoji),
                regular, "style \(style)")
        }
    }

    /// An explicit emoji request resolves to the *pinned* face, in every
    /// style. Asserting the family name alone would prove nothing — the
    /// cascade returns Apple Color Emoji on this machine too — so this
    /// asserts the resolved face is one of the grid's own, which the cascade
    /// results are not.
    func testAnExplicitEmojiRequestResolvesToThePinnedFace() throws {
        let grid = self.grid()
        for style in FontStyle.allCases {
            let index = try XCTUnwrap(
                grid.index(codepoint: Self.emojiOnly, style: style, presentation: .emoji),
                "style \(style)")
            let face = try XCTUnwrap(grid.face(index))
            XCTAssertEqual(try family(grid, index), "Apple Color Emoji", "style \(style)")
            XCTAssertTrue(
                grid.faces(style: style).contains { $0 === face },
                "style \(style): came from the cascade, not from the pin")
        }
    }

    /// And so does an emoji with no presentation stated, since no text face
    /// in the list has the glyph. Same identity check, for the same reason.
    func testAnEmojiWithNoStatedPresentationResolvesToThePinnedFace() throws {
        let grid = self.grid()
        let index = try XCTUnwrap(
            grid.index(codepoint: Self.emojiOnly, style: .regular, presentation: nil))
        let face = try XCTUnwrap(grid.face(index))
        XCTAssertEqual(try family(grid, index), "Apple Color Emoji")
        XCTAssertTrue(grid.faces(style: .regular).contains { $0 === face })
    }

    /// The emoji face does not steal text. U+26A0 is in the font we ship and
    /// in Apple Color Emoji, and with no presentation stated the text face
    /// wins — the face that sets the cell metrics should draw what it can.
    func testTheTextFaceStillWinsForAContestedCodepoint() throws {
        let grid = self.grid()
        let text = try XCTUnwrap(grid.face(style: .regular))
        XCTAssertTrue(text.hasCodepoint(Self.contestedText), "the shipped font lost U+26A0")

        let index = try XCTUnwrap(
            grid.index(codepoint: Self.contestedText, style: .regular, presentation: nil))
        XCTAssertEqual(try family(grid, index), "JetBrains Mono")
    }

    /// Asked for the same codepoint *as emoji*, the colour face answers. The
    /// two assertions together are the rule: presentation decides, not the
    /// order of the list.
    func testAContestedCodepointAsEmojiResolvesToTheColourFace() throws {
        let grid = self.grid()
        let index = try XCTUnwrap(
            grid.index(codepoint: Self.contestedText, style: .regular, presentation: .emoji))
        let face = try XCTUnwrap(grid.face(index))
        XCTAssertTrue(face.hasColor)
        XCTAssertEqual(try family(grid, index), "Apple Color Emoji")
    }

    // MARK: - The presentation rule

    /// The regression this rule exists to prevent, and it is not theoretical:
    /// U+2714 ✔ is the green check a test runner prints, it is in Apple Color
    /// Emoji and in neither face we ship, and it is `Emoji_Presentation=No`.
    ///
    /// Resolved to the colour face it would go into the BGRA atlas, where the
    /// shader samples the bitmap as-is and the cell's foreground is thrown
    /// away — so a green ✔ would come back as a full-colour emoji. It has to
    /// land on a monochrome face instead, which here means the cascade.
    func testATextPresentationSymbolDoesNotGoToTheColourFace() throws {
        let grid = self.grid()
        let index = try XCTUnwrap(
            grid.index(codepoint: Self.checkMark, style: .regular, presentation: nil))
        let face = try XCTUnwrap(grid.face(index))
        XCTAssertNotEqual(try family(grid, index), "Apple Color Emoji")
        XCTAssertFalse(
            face.isColorGlyph(try XCTUnwrap(face.glyphIndex(Self.checkMark))),
            "a text-presentation symbol was resolved to a colour glyph")
    }

    /// And its neighbour goes the other way. U+26A0 ⚠ and U+26A1 ⚡ are
    /// adjacent, both in the font we ship and in Apple Color Emoji, and
    /// nothing a font can see distinguishes them. Unicode says one is text
    /// and the other is emoji, and that is the only reason they resolve
    /// differently.
    func testAdjacentCodepointsResolveByTheirUnicodePresentation() throws {
        let grid = self.grid()
        let shipped = try XCTUnwrap(grid.face(style: .regular))
        XCTAssertTrue(shipped.hasCodepoint(Self.contestedText))
        XCTAssertTrue(shipped.hasCodepoint(Self.contestedEmoji))

        XCTAssertFalse(EmojiPresentation.isEmojiPresentation(Self.contestedText))
        XCTAssertTrue(EmojiPresentation.isEmojiPresentation(Self.contestedEmoji))

        let asText = try XCTUnwrap(
            grid.index(codepoint: Self.contestedText, style: .regular, presentation: nil))
        let asEmoji = try XCTUnwrap(
            grid.index(codepoint: Self.contestedEmoji, style: .regular, presentation: nil))
        XCTAssertEqual(try family(grid, asText), "JetBrains Mono")
        XCTAssertEqual(try family(grid, asEmoji), "Apple Color Emoji")
    }

    /// U+FE0E is somebody saying they meant the text one, and it has to be
    /// obeyed even for a codepoint that is emoji by default.
    func testAnExplicitTextRequestNeverGetsAColourGlyph() throws {
        let grid = self.grid()
        for cp in [Self.contestedText, Self.contestedEmoji] {
            let index = try XCTUnwrap(
                grid.index(codepoint: cp, style: .regular, presentation: .text))
            let face = try XCTUnwrap(grid.face(index))
            XCTAssertFalse(
                face.isColorGlyph(try XCTUnwrap(face.glyphIndex(cp))),
                "U+\(String(cp, radix: 16, uppercase: true)) came back in colour")
        }
    }

    /// A configured family gets the last word about its own glyphs. Menlo has
    /// U+26A1 in monochrome, and somebody who named Menlo should get Menlo's
    /// — the rule is for the faces we reached for, not the one they chose.
    func testAConfiguredFamilyKeepsItsOwnGlyphForAnEmojiCodepoint() throws {
        let grid = self.grid(family: "Menlo")
        let menlo = try XCTUnwrap(grid.face(style: .regular))
        XCTAssertTrue(menlo.hasCodepoint(Self.contestedEmoji), "Menlo lost U+26A1")

        let index = try XCTUnwrap(
            grid.index(codepoint: Self.contestedEmoji, style: .regular, presentation: nil))
        XCTAssertEqual(try family(grid, index), "Menlo")
    }

    /// A configured family is still searched first, which is how somebody
    /// overrides the pin. Menlo has no emoji, so this shows the ordering
    /// rather than the override itself: the pinned face is a fallback and
    /// not a hard-coding.
    func testAConfiguredFamilyIsStillFirst() throws {
        let grid = self.grid(family: "Menlo")
        let list = names(grid, .regular)
        XCTAssertEqual(list.first, "Menlo")
        XCTAssertEqual(list.last, "Apple Color Emoji")

        let index = try XCTUnwrap(
            grid.index(codepoint: Self.emojiOnly, style: .regular, presentation: .emoji))
        XCTAssertEqual(try family(grid, index), "Apple Color Emoji")
    }

    /// The pinned face is asked for by exact name, so a machine that somehow
    /// lacks it degrades to the cascade rather than failing to build a grid.
    func testAGridStillBuildsWhateverTheNameResolvesTo() throws {
        let grid = self.grid()
        XCTAssertGreaterThan(grid.metrics.cellWidth, 0)
        XCTAssertEqual(
            CTFontCopyFamilyName(try XCTUnwrap(grid.face(style: .regular)).font) as String,
            "JetBrains Mono", "the emoji face must never become the primary")
    }
}

/// The Unicode table itself, which is generated rather than written and so
/// could be generated wrong.
final class EmojiPresentationTests: XCTestCase {
    /// Spot values on both sides of the property, chosen so that a table
    /// generated from the wrong column or off by a range fails.
    func testKnownCodepoints() {
        for cp: UInt32 in [0x26A1, 0x1F600, 0x231A, 0x1F3F4, 0x2B50, 0x1F004] {
            XCTAssertTrue(
                EmojiPresentation.isEmojiPresentation(cp),
                "U+\(String(cp, radix: 16, uppercase: true)) should be emoji")
        }
        // Text by default, every one of them a character that turns up in
        // ordinary terminal output.
        for cp: UInt32 in [0x41, 0x2714, 0x2764, 0x2611, 0x27A1, 0x26A0, 0x2122, 0x25B6, 0x2194] {
            XCTAssertFalse(
                EmojiPresentation.isEmojiPresentation(cp),
                "U+\(String(cp, radix: 16, uppercase: true)) should be text")
        }
    }

    /// The binary search, at every boundary it has. A range table is exactly
    /// as good as its edges, and an off-by-one there is invisible in the
    /// middle of a range.
    func testRangeEdges() {
        // U+231A..U+231B is a two-codepoint range with text on both sides.
        XCTAssertFalse(EmojiPresentation.isEmojiPresentation(0x2319))
        XCTAssertTrue(EmojiPresentation.isEmojiPresentation(0x231A))
        XCTAssertTrue(EmojiPresentation.isEmojiPresentation(0x231B))
        XCTAssertFalse(EmojiPresentation.isEmojiPresentation(0x231C))
    }

    /// Below the first range and above the last, which are the two ways a
    /// binary search over a flat pair array goes wrong.
    func testOutsideEveryRange() {
        XCTAssertFalse(EmojiPresentation.isEmojiPresentation(0))
        XCTAssertFalse(EmojiPresentation.isEmojiPresentation(0x20))
        XCTAssertFalse(EmojiPresentation.isEmojiPresentation(0x10FFFF))
    }
}
