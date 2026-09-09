//  SessionNamesTests.swift
//  The name a session gets when nobody typed one.
//
//  Two things are worth holding here, and they fail in different directions.
//
//  The word lists are data, and the failure is total: the server refuses a
//  session name outside `[A-Za-z0-9._-]`, and the `err` it answers with voids
//  every create outstanding on that host. One word added later with an
//  apostrophe or an accent in it would therefore not make one odd session — it
//  would make ⇧⌘N do nothing, for everyone, whenever it came up. So every
//  word in both lists is held against `SessionName.isValid` rather than against
//  a reading of the typing.
//
//  The draw is a policy, and the failure is quiet: a name already on that
//  machine is not refused by the daemon, it is *joined* — so the bug is a new
//  session that never appears and a second tab in one that was already there.
//  The store test in `CurrentHostTests` holds that end to end over a socket;
//  what is here is the part that machine cannot reach, which is what happens
//  when the draw keeps landing on names that are taken.

import IllogicalProtocol
import XCTest

final class SessionNamesTests: XCTestCase {
    /// A pinned generator, so a failure below is one somebody can reproduce
    /// rather than one that was there on a Tuesday. SplitMix64, whose whole
    /// state is the seed — `SystemRandomNumberGenerator` is what the app uses
    /// and is exactly what a test must not.
    private struct PinnedGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Every pair the lists can make.
    private func everyPair() -> Set<String> {
        var pairs: Set<String> = []
        for adjective in SessionNames.adjectives {
            for noun in SessionNames.nouns { pairs.insert("\(adjective)-\(noun)") }
        }
        return pairs
    }

    /// The rule the server enforces, checked against the data rather than the
    /// prose above it. A pair, not just a word: the hyphen has to be legal too,
    /// and the two words plus it have to fit in `maxLength` bytes.
    func testEveryWordAndEveryPairSatisfiesTheNamingRule() {
        for word in SessionNames.adjectives + SessionNames.nouns {
            XCTAssertTrue(SessionName.isValid(word), "\(word) is not a name the server would take")
            XCTAssertEqual(
                word, word.lowercased(),
                "\(word) is capitalized, and the app's other names are not")
        }
        let longestAdjective = SessionNames.adjectives.map { $0.utf8.count }.max() ?? 0
        let longestNoun = SessionNames.nouns.map { $0.utf8.count }.max() ?? 0
        // The `-N` the collision fallback can add is not free either, so this
        // is checked with room for it rather than exactly at the limit.
        XCTAssertLessThanOrEqual(
            longestAdjective + 1 + longestNoun + 2, SessionName.maxLength,
            "the longest pair leaves no room for the numbered fallback")
    }

    /// Non-empty, and no word in both lists.
    ///
    /// Non-empty is not pedantry: the draw indexes into these, so a list
    /// emptied by an edit would trap rather than fail. Disjoint is about what
    /// comes out — a word in both lists is `copper-copper` waiting to happen.
    func testTheListsAreNonEmptyAndDisjoint() {
        XCTAssertFalse(SessionNames.adjectives.isEmpty)
        XCTAssertFalse(SessionNames.nouns.isEmpty)
        XCTAssertEqual(
            Set(SessionNames.adjectives).count, SessionNames.adjectives.count,
            "an adjective is in the list twice")
        XCTAssertEqual(
            Set(SessionNames.nouns).count, SessionNames.nouns.count,
            "a noun is in the list twice")
        XCTAssertTrue(
            Set(SessionNames.adjectives).isDisjoint(with: Set(SessionNames.nouns)),
            "a word in both lists can be drawn against itself")
    }

    /// What a name looks like: one adjective, one hyphen, one noun.
    func testAFreshNameIsAPairFromTheLists() {
        var generator = PinnedGenerator(seed: 20_260_909)
        for _ in 0..<500 {
            let name = SessionNames.fresh(avoiding: [], using: &generator)
            let words = name.split(separator: "-").map(String.init)
            XCTAssertEqual(words.count, 2, "\(name) is not two words")
            guard words.count == 2 else { continue }
            XCTAssertTrue(
                SessionNames.adjectives.contains(words[0]), "\(words[0]) is not in the list")
            XCTAssertTrue(SessionNames.nouns.contains(words[1]), "\(words[1]) is not in the list")
        }
    }

    /// Nothing already on the machine comes back.
    ///
    /// Two hundred draws with each one added to what is taken. That number is
    /// chosen rather than round: against 9,120 pairs the birthday maths puts a
    /// repeat among 200 blind draws at better than nine in ten, so a `fresh`
    /// that had stopped checking `taken` would fail this nearly every seed —
    /// and with the seed pinned, it either fails or does not.
    func testAFreshNameIsNeverOneAlreadyTaken() {
        var generator = PinnedGenerator(seed: 1_009)
        var taken: Set<String> = []
        for _ in 0..<200 {
            let name = SessionNames.fresh(avoiding: taken, using: &generator)
            XCTAssertFalse(taken.contains(name), "\(name) is already on that machine")
            taken.insert(name)
        }
        XCTAssertEqual(taken.count, 200)
    }

    /// With every pair taken there is nothing left to draw, and the fallback
    /// numbers the last one rather than looping forever.
    ///
    /// A number is the thing this whole file exists to get rid of, so it is
    /// worth being clear about why one is acceptable here: the alternative at
    /// this end of the distribution is not a nicer name, it is ⇧⌘N opening a
    /// tab in a session you already had.
    func testEveryPairTakenFallsBackToANumberedOne() {
        var generator = PinnedGenerator(seed: 7)
        let pairs = everyPair()

        let numbered = SessionNames.fresh(avoiding: pairs, using: &generator)

        XCTAssertTrue(numbered.hasSuffix("-2"), "\(numbered) is not the numbered fallback")
        XCTAssertTrue(
            pairs.contains(String(numbered.dropLast(2))), "\(numbered) is not a pair plus a number")
        XCTAssertTrue(SessionName.isValid(numbered), "the server would have refused \(numbered)")
    }

    /// And the number keeps climbing rather than stopping at 2.
    func testTheNumberedFallbackSkipsNumbersInUse() {
        var generator = PinnedGenerator(seed: 11)
        let pairs = everyPair()
        let taken = pairs.union(pairs.map { "\($0)-2" }).union(pairs.map { "\($0)-3" })

        let numbered = SessionNames.fresh(avoiding: taken, using: &generator)

        XCTAssertTrue(numbered.hasSuffix("-4"), "\(numbered) reused a number already there")
    }
}
