//  FontSizeAdjustmentTests.swift
//  Scaling a fallback face so it sits with the face beside it.
//
//  Two faces loaded at the same point size are not the same apparent size.
//  A fallback that is visibly larger or smaller than the text around it is
//  the failure this guards, and it is invisible to every other test here:
//  the glyph still resolves, still rasterizes and still lands in its cell,
//  just drawn a third too big.
//
//  The pure function is tested against numbers rather than fonts, because
//  the interesting cases are the ones no font on the machine provides — a
//  face that states no ex height, a face that measures as zero.

import CoreText
import XCTest

final class FontSizeAdjustmentTests: XCTestCase {
    private static let pointSize: Double = 13
    private static let scale: Double = 2
    /// What every face is asked for before its own adjustment.
    private static var pixelSize: Double { pointSize * scale }

    /// A face that states every metric, so a test can knock out one at a
    /// time and know that is the only thing that changed.
    private func metrics(
        pxPerEm: Double = 100,
        cellWidth: Double = 60,
        ascent: Double = 80,
        descent: Double = -20,
        lineGap: Double = 0,
        capHeight: Double? = 70,
        exHeight: Double? = 50,
        asciiHeight: Double? = 75,
        icWidth: Double? = 100
    ) -> FaceMetrics {
        FaceMetrics(
            pxPerEm: pxPerEm, cellWidth: cellWidth, ascent: ascent, descent: descent,
            lineGap: lineGap, underlinePosition: nil, underlineThickness: nil,
            strikethroughPosition: nil, strikethroughThickness: nil, capHeight: capHeight,
            exHeight: exHeight, asciiHeight: asciiHeight, icWidth: icWidth)
    }

    private func factor(
        _ primary: FaceMetrics, _ face: FaceMetrics, _ adjustment: SizeAdjustment
    ) -> Double {
        FaceMetrics.scaleFactor(primary: primary, face: face, adjustment: adjustment)
    }

    // MARK: - The arithmetic

    /// `.none` is the identity, and it is what the symbols and emoji faces
    /// are added with.
    func testNoAdjustmentIsTheIdentity() {
        let half = metrics(icWidth: 50)
        XCTAssertEqual(factor(metrics(), half, .none), 1)
    }

    /// A face already matching the primary is left alone, even though the
    /// two were measured at different sizes. That is what normalizing to
    /// ems buys.
    func testAMatchingFaceIsNotScaled() {
        let primary = metrics(pxPerEm: 100, icWidth: 100)
        let same = metrics(pxPerEm: 50, cellWidth: 30, icWidth: 50)
        XCTAssertEqual(factor(primary, same, .icWidth), 1, accuracy: 1e-12)
    }

    /// The ratio itself: an ideograph half as wide, per em, is scaled up by
    /// two so that it lands on the same grid.
    func testTheFactorIsTheRatioOfTheChosenMetric() {
        let primary = metrics(icWidth: 100)
        let narrow = metrics(icWidth: 50)
        XCTAssertEqual(factor(primary, narrow, .icWidth), 2, accuracy: 1e-12)

        let wide = metrics(icWidth: 200)
        XCTAssertEqual(factor(primary, wide, .icWidth), 0.5, accuracy: 1e-12)
    }

    // MARK: - The fallthrough chain

    /// A face that states no ideograph width is measured by ex height
    /// instead. This is the common case and not an exotic one: no ordinary
    /// Latin monospace font has 水 in it, so every Latin fallback lands here.
    func testAFaceWithNoIdeographFallsThroughToExHeight() {
        let primary = metrics(exHeight: 50, icWidth: 100)
        let noIC = metrics(exHeight: 25, icWidth: nil)
        // Not the ic ratio, which the estimator would have made 1.
        XCTAssertEqual(factor(primary, noIC, .icWidth), 2, accuracy: 1e-12)
    }

    /// Each step falls to the next, ending at line height, which every font
    /// has because it is computed rather than read.
    func testTheChainWalksToLineHeight() {
        let primary = metrics(ascent: 80, descent: -20, capHeight: 70, exHeight: 50)
        let bare = metrics(
            ascent: 40, descent: -10, capHeight: nil, exHeight: nil, asciiHeight: nil,
            icWidth: nil)
        // 100 per em against 50 per em.
        XCTAssertEqual(factor(primary, bare, .icWidth), 2, accuracy: 1e-12)
    }

    /// A stated-but-nonsense metric counts as absent. A zero ex height is a
    /// font saying nothing in a more annoying way, and dividing by it is how
    /// a face ends up loaded at a size of infinity.
    func testAZeroMetricIsTreatedAsAbsent() {
        let primary = metrics(exHeight: 50, icWidth: 100)
        let zeroed = metrics(exHeight: 0, icWidth: 0)
        let f = factor(primary, zeroed, .icWidth)
        XCTAssertTrue(f.isFinite)
        XCTAssertGreaterThan(f, 0)
    }

    /// A face CoreText half-understands can measure as zero on every axis.
    /// libghostty has no guard here because FreeType will not hand it such a
    /// face; CoreText will.
    func testADegenerateFaceIsNotScaled() {
        let primary = metrics()
        let degenerate = metrics(
            pxPerEm: 0, cellWidth: 0, ascent: 0, descent: 0, lineGap: 0, capHeight: nil,
            exHeight: nil, asciiHeight: nil, icWidth: nil)
        XCTAssertEqual(factor(primary, degenerate, .icWidth), 1)
        XCTAssertEqual(factor(degenerate, primary, .icWidth), 1)
    }

    // MARK: - Through the grid

    private func size(_ face: FontFace) -> Double { Double(CTFontGetSize(face.font)) }

    private func face(_ grid: FontGrid, _ family: String) throws -> FontFace {
        let match = grid.faces(style: .regular).first {
            (CTFontCopyFamilyName($0.font) as String) == family
        }
        return try XCTUnwrap(match, "\(family) is not in the grid")
    }

    /// Nothing configured means the font we ship *is* the primary, so it is
    /// asked for at exactly the size the grid wants and scaled by nothing.
    /// A factor that crept in here would resize the whole terminal.
    func testTheDefaultPrimaryIsNeverScaled() throws {
        let grid = FontGridSet.grid(family: nil, pointSize: Self.pointSize, scale: Self.scale)
        for style in FontStyle.allCases {
            let primary = try XCTUnwrap(grid.face(style: style))
            XCTAssertEqual(size(primary), Self.pixelSize, accuracy: 1e-9, "style \(style)")
        }
    }

    /// The point of the change. Courier New has a much smaller ex height
    /// than the font we ship, so behind it our face is loaded smaller — and
    /// the two now measure the same on screen, which is what "matches" means.
    func testTheShippedFontIsScaledToAConfiguredFamily() throws {
        let grid = FontGridSet.grid(
            family: "Courier New", pointSize: Self.pointSize, scale: Self.scale)
        let courier = try face(grid, "Courier New")
        let ours = try face(grid, "JetBrains Mono")

        XCTAssertEqual(size(courier), Self.pixelSize, accuracy: 1e-9, "the primary moved")
        XCTAssertLessThan(size(ours), Self.pixelSize - 1, "our face was not scaled down")

        // Same apparent size, which is the whole claim.
        XCTAssertEqual(
            ours.faceMetrics().resolvedExHeight(),
            courier.faceMetrics().resolvedExHeight(),
            accuracy: 0.5)
    }

    /// Every style is scaled, not just regular. A bold that kept the
    /// unadjusted size would jump a size mid-line.
    func testEveryStyleOfTheShippedFontIsScaled() throws {
        let grid = FontGridSet.grid(
            family: "Courier New", pointSize: Self.pointSize, scale: Self.scale)
        for style in FontStyle.allCases {
            let ours = try XCTUnwrap(
                grid.faces(style: style).first {
                    (CTFontCopyFamilyName($0.font) as String) == "JetBrains Mono"
                }, "style \(style)")
            XCTAssertLessThan(size(ours), Self.pixelSize - 1, "style \(style)")
        }
    }

    /// The symbols face is added with `.none`, so it keeps the grid's size
    /// whatever family is in front of it. Scaling it would fight
    /// `NerdFontConstraints`, which fits each icon to the cell itself.
    func testTheSymbolsFaceIsNeverScaled() throws {
        for family in [nil, "Courier New"] {
            let grid = FontGridSet.grid(
                family: family, pointSize: Self.pointSize, scale: Self.scale)
            let symbols = try face(grid, "Symbols Nerd Font")
            XCTAssertEqual(
                size(symbols), Self.pixelSize, accuracy: 1e-9,
                "family \(family ?? "nil")")
        }
    }

    /// A CJK face found through the system cascade is scaled, and this is
    /// the one path that reaches `.icWidth` for real: a Han face states an
    /// ideograph width where no Latin font does.
    ///
    /// What it is matched *to* is the primary's own ic width, which for a
    /// Latin face is an estimate — `min(asciiHeight, 2 * cellWidth)` — and
    /// not two cells exactly. That is libghostty's arrangement and it is
    /// worth being precise about: the promise is that the two faces agree,
    /// not that an ideograph fills a pair of cells edge to edge.
    func testACascadedCJKFallbackIsScaled() throws {
        let grid = FontGridSet.grid(family: nil, pointSize: Self.pointSize, scale: Self.scale)
        // 水 itself: the character the metric is defined in terms of.
        guard let index = grid.index(codepoint: 0x6C34, style: .regular, presentation: nil),
            let han = grid.face(index)
        else { throw XCTSkip("no CJK font on this machine") }

        XCTAssertNotEqual(CTFontCopyFamilyName(han.font) as String, "JetBrains Mono")
        XCTAssertNotNil(han.faceMetrics().icWidth, "the fallback states no ic width")

        let target = try XCTUnwrap(grid.face(style: .regular)).faceMetrics().resolvedIcWidth()
        XCTAssertEqual(han.faceMetrics().resolvedIcWidth(), target, accuracy: 0.5)

        // And the scale is what did it: the same face at the grid's own size
        // does not agree, so the assertion above cannot pass by luck.
        let unscaled = FontFace(
            font: CTFontCreateCopyWithAttributes(han.font, Self.pixelSize, nil, nil))
        XCTAssertNotEqual(
            unscaled.faceMetrics().resolvedIcWidth(), target, accuracy: 0.5,
            "the fallback already matched, so this test proves nothing here")
    }

    /// Colour faces are exempt. Apple Color Emoji is a bitmap strike whose
    /// ex height has nothing to do with text, so a factor computed from it
    /// would resize emoji for no reason; libghostty passes `.none` there too.
    func testAColourFallbackIsNotScaled() throws {
        let grid = FontGridSet.grid(family: nil, pointSize: Self.pointSize, scale: Self.scale)
        guard let index = grid.index(codepoint: 0x1F600, style: .regular, presentation: .emoji),
            let emoji = grid.face(index)
        else { throw XCTSkip("no colour emoji font on this machine") }

        XCTAssertTrue(emoji.hasColor)
        XCTAssertEqual(size(emoji), Self.pixelSize, accuracy: 1e-9)
    }
}
