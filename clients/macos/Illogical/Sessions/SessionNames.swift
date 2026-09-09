//  SessionNames.swift
//  The name a session gets when nobody typed one.
//
//  Two words and a hyphen — `drifting-cedar`, `cosmic-summit` — drawn from the
//  lists below. What this replaces is `session-1`, `session-2`, `session-3`,
//  and the reason is that a session name is the one label the app asks you to
//  recognise: it is what the dropdown lists, what the session button says, what
//  ⌘K matches against, and what `illogical rename` takes. Numbers are perfect
//  identifiers and hopeless names. Three of them on screen at once are three
//  rows nobody can tell apart without opening each, and the machine already has
//  an identifier for a session — the id, which is the thing every frame carries
//  and the thing no user ever has to read.
//
//  A generated name is a *starting* name, not a permanent one. Rename is right
//  there (see docs/CLIENT.md, "Renaming and deleting"), and `drifting-cedar`
//  being obviously arbitrary is part of the point: nothing about it suggests
//  the app knows what the session is for, so it reads as a handle rather than
//  as a description that has gone stale.
//
//  Both lists are ASCII, lower-case, and free of `-`, so every pair satisfies
//  `SessionName.isValid` — the server refuses anything outside `[A-Za-z0-9._-]`
//  on `create`, and an `err` there voids every create outstanding on that host.
//  A word list that drifted outside the rule would therefore break ⇧⌘N for
//  everyone at once, which is why `SessionNamesTests` holds every word in both
//  lists against `isValid` rather than trusting the typing here.

/// Where a fresh session's name comes from.
enum SessionNames {
    /// How many pairs to draw before giving up on an unused one.
    ///
    /// The lists multiply out to thousands of pairs, so a collision on the
    /// first draw means a machine already holding a large share of them and
    /// redrawing forever would be the wrong shape of loop — this is a name, and
    /// there is a fallback that always terminates. Sixteen is far past the
    /// point where an unused pair exists but was missed: with even half the
    /// space taken, sixteen draws miss one in 65,536 times.
    private static let drawLimit = 16

    /// A name for a new session on a machine already holding `taken`.
    ///
    /// **Avoiding the taken names is not cosmetic.** A `create` is addressed by
    /// name and `Server.sessionByNameLocked` *joins* a session whose name it
    /// already has rather than refusing it, so proposing a name already on that
    /// machine does not produce a second session with a confusing label — it
    /// produces no new session at all, and opens a tab inside the one that was
    /// already there. That was the whole of the `session-N` bug this replaces
    /// (`count + 1` named a session still on screen once a lower-numbered one
    /// had been deleted), and it survives the change to random names, so the
    /// check does too.
    ///
    /// Exact comparison, mirroring the server's `mem.eql` — the same reasoning
    /// `renameRefusal` sets out. Every name this makes is lower-case, so a
    /// case-insensitive check here could only ever skip a pair the daemon would
    /// have given us.
    static func fresh(avoiding taken: Set<String>) -> String {
        var generator = SystemRandomNumberGenerator()
        return fresh(avoiding: taken, using: &generator)
    }

    /// The above, against a generator a test can pin.
    static func fresh(
        avoiding taken: Set<String>, using generator: inout some RandomNumberGenerator
    ) -> String {
        var pair = ""
        for _ in 0..<drawLimit {
            pair = draw(using: &generator)
            if !taken.contains(pair) { return pair }
        }
        // Every draw landed on a name that is already there. Numbering the last
        // one is the fallback rather than a further search, because it is the
        // one step that cannot fail to terminate: the set is finite, so some N
        // is free. It reintroduces a number, which is the thing this file
        // exists to get rid of — and that is the right trade at this end of the
        // distribution, where the alternative is ⇧⌘N opening a tab in a session
        // you already had.
        var index = 2
        while taken.contains("\(pair)-\(index)") { index += 1 }
        return "\(pair)-\(index)"
    }

    /// One pair, with no regard for what is taken.
    private static func draw(using generator: inout some RandomNumberGenerator) -> String {
        let adjective = adjectives[Int.random(in: adjectives.indices, using: &generator)]
        let noun = nouns[Int.random(in: nouns.indices, using: &generator)]
        return "\(adjective)-\(noun)"
    }

    /// The first word.
    ///
    /// Chosen to be atmospheric rather than descriptive — nothing here claims
    /// anything about the session — and to read as an adjective on its own, so
    /// that no pair comes out as two nouns stuck together. Words that are both
    /// (`copper`, `ember`, `hollow`) are in one list only, and the one they are
    /// in is the one where they never produce a stumble.
    static let adjectives: [String] = [
        "amber", "ancient", "arctic", "ashen", "autumn", "azure",
        "boreal", "bright", "brisk", "calm", "cobalt", "copper",
        "cosmic", "crimson", "crystal", "dappled", "distant", "drifting",
        "dusky", "eager", "elder", "endless", "faded", "fearless",
        "fleeting", "floating", "frosted", "gentle", "gilded", "glacial",
        "gleaming", "golden", "hidden", "humble", "idle", "indigo",
        "ivory", "jagged", "keen", "lasting", "lively", "lofty",
        "lucid", "lunar", "mellow", "midnight", "mighty", "misty",
        "molten", "mossy", "muted", "noble", "northern", "patient",
        "placid", "polar", "primal", "quiet", "radiant", "restless",
        "rising", "roaming", "rugged", "rustic", "sable", "scarlet",
        "serene", "shaded", "shifting", "silent", "silver", "sleepy",
        "slender", "smoky", "solar", "solemn", "southern", "steady",
        "stellar", "still", "stormy", "sunlit", "swift", "tender",
        "tidal", "tranquil", "umber", "vast", "velvet", "verdant",
        "violet", "wandering", "wild", "windy", "wistful", "woven",
    ]

    /// The second word: something concrete, from landscape, weather and sky.
    ///
    /// Concrete on purpose. `drifting-cedar` is a picture and is remembered as
    /// one; `drifting-notion` is two abstractions and is remembered as neither.
    static let nouns: [String] = [
        "alcove", "anchor", "arbor", "ash", "aspen", "atlas",
        "basin", "beacon", "bluff", "bramble", "brook", "cairn",
        "canyon", "cedar", "cinder", "cirrus", "cliff", "comet",
        "copse", "coral", "cove", "crag", "crater", "creek",
        "crest", "delta", "dune", "ember", "fathom", "fern",
        "fjord", "forge", "fountain", "garden", "gully", "harbor",
        "harvest", "haven", "heath", "hollow", "horizon", "isle",
        "jetty", "juniper", "lagoon", "lantern", "ledge", "lichen",
        "lodge", "maple", "meadow", "mesa", "meteor", "mirage",
        "moor", "moss", "nebula", "oasis", "orbit", "orchard",
        "pebble", "pine", "plateau", "prairie", "quarry", "quill",
        "rapids", "ravine", "reef", "ridge", "rill", "river",
        "shoal", "shore", "sierra", "slate", "solstice", "sparrow",
        "spire", "spring", "spruce", "station", "steppe", "summit",
        "tarn", "thicket", "thorn", "tide", "timber", "tundra",
        "valley", "vista", "willow", "zenith", "zephyr",
    ]
}
