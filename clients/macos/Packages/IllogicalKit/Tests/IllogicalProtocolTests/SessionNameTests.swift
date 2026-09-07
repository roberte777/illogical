//  SessionNameTests.swift
//  The client half of the naming rule.
//
//  The cases are `validateName`'s own, from src/core/session.zig, verbatim:
//  the two implementations disagreeing means a name the field accepts and the
//  server then refuses, which reverts silently on the next list.

import Testing

@testable import IllogicalProtocol

@Suite("Session names")
struct SessionNameTests {
    @Test("accepts the names the server accepts")
    func accepts() {
        #expect(SessionName.isValid("build"))
        #expect(SessionName.isValid("agent-07_x.2"))
        #expect(SessionName.isValid("x"))
        #expect(SessionName.isValid(String(repeating: "x", count: SessionName.maxLength)))
    }

    @Test("refuses the names the server refuses")
    func refuses() {
        #expect(!SessionName.isValid(""))
        #expect(!SessionName.isValid("has space"))
        // Names reach file paths in the park store, which is why the rule is
        // this boring.
        #expect(!SessionName.isValid("../escape"))
        #expect(!SessionName.isValid(String(repeating: "x", count: SessionName.maxLength + 1)))
    }

    @Test("the length limit is in bytes, as the server measures it")
    func lengthIsBytes() {
        #expect(SessionName.maxLength == 64)
        // Multi-byte characters are outside the character class anyway, so the
        // two rules cannot disagree about where the limit falls.
        #expect(!SessionName.isValid("é"))
        #expect(!SessionName.isValid("naïve"))
    }
}
