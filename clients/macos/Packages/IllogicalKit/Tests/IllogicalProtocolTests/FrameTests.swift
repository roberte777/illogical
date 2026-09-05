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
    }
}
