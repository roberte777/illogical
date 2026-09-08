import Foundation
import Testing

@testable import IllogicalProtocol

@Suite("Frame header codec")
struct FrameHeaderTests {
    @Test("round trips")
    func roundTrip() throws {
        let want = FrameHeader(type: .output, session: 0xDEAD_BEEF_CAFE, length: 4096)
        let got = try FrameHeader.decode(want.encoded)
        #expect(got == want)
    }

    @Test("header is exactly the advertised width")
    func headerWidth() {
        let header = FrameHeader(type: .ping, session: 0, length: 0)
        #expect(header.encoded.count == Protocol.headerLength)
    }

    @Test("rejects a truncated header")
    func rejectsShort() {
        let bytes = FrameHeader(type: .ping, session: 1, length: 0).encoded.dropLast()
        #expect(throws: FrameHeader.DecodeError.short) {
            _ = try FrameHeader.decode(bytes)
        }
    }

    @Test("rejects an unknown frame type")
    func rejectsUnknownType() {
        var bytes = FrameHeader(type: .ping, session: 1, length: 0).encoded
        bytes[0] = 0x7F
        #expect(throws: FrameHeader.DecodeError.unknownFrameType(0x7F)) {
            _ = try FrameHeader.decode(bytes)
        }
    }

    @Test("rejects an oversized payload")
    func rejectsOversized() {
        let bytes = FrameHeader(
            type: .output, session: 1, length: Protocol.maxPayloadLength + 1
        ).encoded
        #expect(throws: FrameHeader.DecodeError.payloadTooLarge(Protocol.maxPayloadLength + 1)) {
            _ = try FrameHeader.decode(bytes)
        }
    }

    @Test("frame direction matches the high bit")
    func direction() {
        #expect(FrameType.input.isClientToServer)
        #expect(!FrameType.output.isClientToServer)
        #expect(FrameType.renameSession.isClientToServer)
        #expect(FrameType.deleteSession.isClientToServer)
        #expect(!FrameType.resized.isClientToServer)
    }

    // The numbers, not just the names. This file and src/core/protocol.zig are
    // one protocol written twice, and a value that drifts is a frame the other
    // side either refuses or, worse, mistakes for a different one. The Zig
    // suite asserts the same constants.
    @Test("the session-scoped frames carry the values the server assigns")
    func sessionScopedFrameValues() {
        #expect(FrameType.renameSession.rawValue == 0x0B)
        #expect(FrameType.deleteSession.rawValue == 0x0C)
    }

    @Test("the naming error codes carry the values the server sends")
    func namingErrorCodes() {
        #expect(ProtocolErrorCode.invalidName.rawValue == 8)
        #expect(ProtocolErrorCode.nameInUse.rawValue == 9)
    }
}
