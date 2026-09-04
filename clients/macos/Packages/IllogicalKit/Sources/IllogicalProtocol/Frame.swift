//  Frame.swift
//  The client half of the illogical wire protocol.
//
//  This must stay byte-for-byte in step with src/core/protocol.zig. The frame
//  header is deliberately trivial so that decoding output frames — by far the
//  hottest path — costs nothing but a bounds check.

import Foundation

public enum Protocol {
    /// Bumped on any incompatible change. Mirrors `protocol.version`.
    public static let version: UInt16 = 1

    /// Reserved session id for connection-level control frames.
    public static let controlSession: UInt64 = 0

    public static let headerLength = 13

    /// Largest payload accepted in a single frame. Mirrors `max_payload_len`.
    public static let maxPayloadLength: UInt32 = 1 << 20
}

public enum FrameType: UInt8, Sendable {
    // client -> server
    case hello = 0x01
    case list = 0x02
    case create = 0x03
    case attach = 0x04
    case detach = 0x05
    case kill = 0x06
    case input = 0x07
    case resize = 0x08
    case ping = 0x09

    // server -> client
    case welcome = 0x81
    case sessionList = 0x82
    case created = 0x83
    case snapshotBegin = 0x84
    case snapshotChunk = 0x85
    case snapshotReady = 0x86
    case snapshotEnd = 0x87
    case output = 0x88
    case exited = 0x89
    case sessionsChanged = 0x8A
    case error = 0x8B
    case pong = 0x8C

    public var isClientToServer: Bool { rawValue < 0x80 }
}

public struct FrameHeader: Equatable, Sendable {
    public var type: FrameType
    public var session: UInt64
    public var length: UInt32

    public init(type: FrameType, session: UInt64, length: UInt32) {
        self.type = type
        self.session = session
        self.length = length
    }

    public func encode(into buffer: inout Data) {
        buffer.append(type.rawValue)
        withUnsafeBytes(of: session.littleEndian) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: length.littleEndian) { buffer.append(contentsOf: $0) }
    }

    public var encoded: Data {
        var data = Data(capacity: Protocol.headerLength)
        encode(into: &data)
        return data
    }

    public enum DecodeError: Error, Equatable {
        case short
        case unknownFrameType(UInt8)
        case payloadTooLarge(UInt32)
    }

    /// Decode a header from the first ``Protocol/headerLength`` bytes of `bytes`.
    public static func decode(_ bytes: some Collection<UInt8>) throws -> FrameHeader {
        guard bytes.count >= Protocol.headerLength else { throw DecodeError.short }
        var iterator = bytes.makeIterator()
        var raw = [UInt8]()
        raw.reserveCapacity(Protocol.headerLength)
        for _ in 0..<Protocol.headerLength {
            guard let byte = iterator.next() else { throw DecodeError.short }
            raw.append(byte)
        }

        guard let type = FrameType(rawValue: raw[0]) else {
            throw DecodeError.unknownFrameType(raw[0])
        }
        let session = raw[1..<9].reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let length = raw[9..<13].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= Protocol.maxPayloadLength else {
            throw DecodeError.payloadTooLarge(length)
        }
        return FrameHeader(type: type, session: session, length: length)
    }
}

/// Error codes carried by an ``FrameType/error`` frame. Mirrors `ErrorCode`.
public enum ProtocolErrorCode: UInt16, Sendable {
    case unknown = 0
    case versionMismatch = 1
    case noSuchSession = 2
    case sessionBusy = 3
    case spawnFailed = 4
    case unparkFailed = 5
    case malformedFrame = 6
}
