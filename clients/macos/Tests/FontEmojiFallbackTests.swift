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
    /// High voltage: in the font we ship, in the symbols face, and in Apple
    /// Color Emoji. The codepoint where "which face answers" is a real
    /// question rather than a formality.
    private static let contested: UInt32 = 0x26A1

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

    /// An explicit emoji request resolves to the pinned face, in every
    /// style. Before this the request skipped the grid's list entirely and
    /// went straight to the cascade.
    func testAnExplicitEmojiRequestResolvesToThePinnedFace() throws {
        let grid = self.grid()
        for style in FontStyle.allCases {
            let index = try XCTUnwrap(
                grid.index(codepoint: Self.emojiOnly, style: style, presentation: .emoji),
                "style \(style)")
            XCTAssertEqual(try family(grid, index), "Apple Color Emoji", "style \(style)")
        }
    }

    /// And so does an emoji with no presentation stated, since no text face
    /// in the list has the glyph.
    func testAnEmojiWithNoStatedPresentationResolvesToThePinnedFace() throws {
        let grid = self.grid()
        let index = try XCTUnwrap(
            grid.index(codepoint: Self.emojiOnly, style: .regular, presentation: nil))
        XCTAssertEqual(try family(grid, index), "Apple Color Emoji")
    }

    /// The emoji face does not steal text. U+26A1 is in the font we ship and
    /// in Apple Color Emoji, and with no presentation stated the text face
    /// wins — the face that sets the cell metrics should draw what it can.
    func testTheTextFaceStillWinsForAContestedCodepoint() throws {
        let grid = self.grid()
        let text = try XCTUnwrap(grid.face(style: .regular))
        XCTAssertTrue(text.hasCodepoint(Self.contested), "the shipped font lost U+26A1")

        let index = try XCTUnwrap(
            grid.index(codepoint: Self.contested, style: .regular, presentation: nil))
        XCTAssertEqual(try family(grid, index), "JetBrains Mono")
    }

    /// Asked for the same codepoint *as emoji*, the colour face answers. The
    /// two assertions together are the rule: presentation decides, not the
    /// order of the list.
    func testAContestedCodepointAsEmojiResolvesToTheColourFace() throws {
        let grid = self.grid()
        let index = try XCTUnwrap(
            grid.index(codepoint: Self.contested, style: .regular, presentation: .emoji))
        let face = try XCTUnwrap(grid.face(index))
        XCTAssertTrue(face.hasColor)
        XCTAssertEqual(try family(grid, index), "Apple Color Emoji")
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
