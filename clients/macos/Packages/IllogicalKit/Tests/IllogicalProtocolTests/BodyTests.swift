//  BodyTests.swift
//  What the control bodies actually put on the wire.
//
//  The Zig side parses these with `std.json.parseFromSlice` into a struct whose
//  field names *are* the keys, so a Swift property renamed without its
//  `CodingKeys` is a frame the server rejects at parse time. Keys are asserted
//  against a decoded dictionary rather than against a JSON string, because
//  `JSONEncoder` makes no promise about key order.

import Foundation
import Testing

@testable import IllogicalProtocol

@Suite("Control body encoding")
struct BodyTests {
    private func keyedJSON(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("rename carries the session id and the name the server reads")
    func renameKeys() throws {
        let json = try keyedJSON(RenameSessionBody(session: 7, name: "done"))
        #expect(Set(json.keys) == ["session", "name"])
        #expect(json["session"] as? UInt64 == 7)
        #expect(json["name"] as? String == "done")
    }

    @Test("delete spells only_if_empty the way the server does")
    func deleteKeys() throws {
        let json = try keyedJSON(DeleteSessionBody(session: 3))
        // Snake case, not `onlyIfEmpty`: the Zig struct's field name is the key.
        #expect(Set(json.keys) == ["session", "only_if_empty"])
        #expect(json["session"] as? UInt64 == 3)
        // Cascading is the default; a careful script has to ask.
        #expect(json["only_if_empty"] as? Bool == false)

        let careful = try keyedJSON(DeleteSessionBody(session: 3, onlyIfEmpty: true))
        #expect(careful["only_if_empty"] as? Bool == true)
    }

    @Test("hello asks for resized by name, and an old server's welcome says nothing")
    func resizedCapability() throws {
        // The key the daemon reads; a client that sends it is one that can
        // decode the frame, which is the only client the daemon may send it to.
        let hello = try keyedJSON(HelloBody(client: "test", resized: true))
        #expect(hello["resized"] as? Bool == true)
        let quiet = try keyedJSON(HelloBody(client: "test"))
        #expect(quiet["resized"] as? Bool == false)

        // A welcome from before the frame existed. It must decode, and it
        // must read as "no": against that server the client sizes its own
        // terminal, as it always did.
        let old = try JSONDecoder().decode(
            WelcomeBody.self, from: Data(#"{"version":1,"server":"old"}"#.utf8))
        #expect(old.resized == nil)
        let new = try JSONDecoder().decode(
            WelcomeBody.self, from: Data(#"{"version":1,"server":"new","resized":true}"#.utf8))
        #expect(new.resized == true)

        let resized = try JSONDecoder().decode(
            ResizedBody.self, from: Data(#"{"cols":132,"rows":43}"#.utf8))
        #expect(resized.cols == 132)
        #expect(resized.rows == 43)
    }

    @Test("both bodies round trip")
    func roundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let rename = try decoder.decode(
            RenameSessionBody.self,
            from: encoder.encode(RenameSessionBody(session: 7, name: "agent-07_x.2")))
        #expect(rename.session == 7)
        #expect(rename.name == "agent-07_x.2")

        let delete = try decoder.decode(
            DeleteSessionBody.self,
            from: encoder.encode(DeleteSessionBody(session: 3, onlyIfEmpty: true)))
        #expect(delete.session == 3)
        #expect(delete.onlyIfEmpty)
    }
}
