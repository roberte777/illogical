//  Connection.swift
//  A connection to illogicald.
//
//  Frames arrive on a dedicated reader thread and are published as an
//  AsyncStream. Writes are serialized by a lock, because terminal output and
//  user input come from different threads.
//
//  One connection per terminal, per docs/PROTOCOL.md.

import Darwin
import Foundation

public struct Frame: Sendable {
    public let type: FrameType
    public let terminal: UInt64
    public let payload: Data

    public init(type: FrameType, terminal: UInt64, payload: Data) {
        self.type = type
        self.terminal = terminal
        self.payload = payload
    }
}

public enum ConnectionError: Error, Equatable {
    case socketFailed(Int32)
    case connectFailed(Int32)
    case pathTooLong
    case closed
    case handshakeFailed(String)
    case unexpectedFrame(FrameType)
}

public final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    private var readerThread: Thread?
    private let closed = ManagedAtomicFlag()

    /// Frames from the server. Finishes when the connection closes.
    public let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation

    public init(socketPath: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectionError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            throw ConnectionError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ConnectionError.connectFailed(code)
        }

        self.fd = fd
        var captured: AsyncStream<Frame>.Continuation?
        self.frames = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        // AsyncStream runs its build closure synchronously, so this is set.
        guard let continuation = captured else {
            preconditionFailure("AsyncStream did not provide a continuation")
        }
        self.continuation = continuation
    }

    deinit {
        close()
    }

    public func start() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "illogical.connection"
        thread.stackSize = 512 * 1024
        thread.start()
        readerThread = thread
    }

    public func close() {
        guard closed.testAndSet() == false else { return }
        Darwin.close(fd)
        continuation.finish()
    }

    // MARK: - Sending

    public func send(
        _ type: FrameType, terminal: UInt64 = Protocol.controlSession, payload: Data = Data()
    )
        throws
    {
        var frame = FrameHeader(
            type: type, session: terminal, length: UInt32(payload.count)
        ).encoded
        frame.append(payload)

        writeLock.lock()
        defer { writeLock.unlock() }
        try frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ConnectionError.closed
                }
                offset += n
            }
        }
    }

    public func send<T: Encodable>(
        _ type: FrameType, terminal: UInt64 = Protocol.controlSession, json: T
    )
        throws
    {
        let encoder = JSONEncoder()
        try send(type, terminal: terminal, payload: encoder.encode(json))
    }

    // MARK: - Reading

    private func readLoop() {
        var header = [UInt8](repeating: 0, count: Protocol.headerLength)
        while !closed.isSet {
            guard readExact(into: &header, count: Protocol.headerLength) else { break }
            guard let parsed = try? FrameHeader.decode(header) else { break }

            var payload = Data()
            if parsed.length > 0 {
                var buf = [UInt8](repeating: 0, count: Int(parsed.length))
                guard readExact(into: &buf, count: Int(parsed.length)) else { break }
                payload = Data(buf)
            }
            continuation.yield(
                Frame(type: parsed.type, terminal: parsed.session, payload: payload))
        }
        continuation.finish()
    }

    private func readExact(into buf: inout [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = buf.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            offset += n
        }
        return true
    }
}

/// Minimal atomic flag. Avoids a dependency on swift-atomics for one bit.
final class ManagedAtomicFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Sets the flag and returns its previous value.
    @discardableResult
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = true
        return old
    }
}

// MARK: - Control message bodies
//
// These mirror `protocol.body` in src/core/protocol.zig. Only control frames
// are JSON; output, input and snapshot chunks are raw bytes.

public struct HelloBody: Codable, Sendable {
    public var version: UInt16 = Protocol.version
    public var client: String
    public init(client: String) { self.client = client }
}

public struct WelcomeBody: Codable, Sendable {
    public var version: UInt16
    public var server: String
}

public struct CreateBody: Codable, Sendable {
    public var sessionName: String
    public var name: String
    public var argv: [String]
    public var cwd: String?
    public var cols: UInt16
    public var rows: UInt16

    enum CodingKeys: String, CodingKey {
        case sessionName = "session_name"
        case name, argv, cwd, cols, rows
    }

    public init(
        sessionName: String = "default",
        name: String = "",
        argv: [String] = [],
        cwd: String? = nil,
        cols: UInt16 = 80,
        rows: UInt16 = 24
    ) {
        self.sessionName = sessionName
        self.name = name
        self.argv = argv
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
    }
}

public struct CreatedBody: Codable, Sendable {
    public var terminal: UInt64
    public var session: UInt64
}

public struct TerminalInfoBody: Codable, Sendable {
    public var id: UInt64
    public var session: UInt64
    public var name: String
    public var command: String
    public var cwd: String
    public var cols: UInt16
    public var rows: UInt16
    public var residency: String
    public var attached: UInt32
    public var ptyReadIdleNanoseconds: UInt64
    public var exitCode: Int32?

    enum CodingKeys: String, CodingKey {
        case id, session, name, command, cwd, cols, rows, residency, attached
        case ptyReadIdleNanoseconds = "pty_read_idle_ns"
        case exitCode = "exit_code"
    }
}

public struct SessionInfoBody: Codable, Sendable {
    public var id: UInt64
    public var name: String
    public var terminals: [UInt64]
}

public struct SessionListBody: Codable, Sendable {
    public var sessions: [SessionInfoBody]
    public var terminals: [TerminalInfoBody]
}

public struct AttachBody: Codable, Sendable {
    public var cols: UInt16
    public var rows: UInt16
    public init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }
}

public struct ResizeBody: Codable, Sendable {
    public var cols: UInt16
    public var rows: UInt16
    public init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }
}

public struct ErrBody: Codable, Sendable {
    public var code: UInt16
    public var message: String
}

public struct ExitedBody: Codable, Sendable {
    public var code: Int32
}
