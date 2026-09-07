//  Connection.swift
//  A connection to illogicald.
//
//  Frames arrive on a dedicated reader thread and are published as an
//  AsyncStream. Writes are serialized by a lock, because terminal output and
//  user input come from different threads.
//
//  One connection per terminal, per docs/PROTOCOL.md.
//
//  Nothing here knows whether the daemon is on this machine or another one.
//  That is a `Transport`: a unix socket locally, `ssh <dest> illogicald
//  --stdio` remotely, with the same frames on a pipe. See Transport.swift.

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

/// What a *connection* can fail at, once it exists.
///
/// Connecting throws `TransportError` now, so the three cases that used to
/// duplicate it — `socketFailed`, `connectFailed`, `pathTooLong` — became
/// unreachable when the transport took over opening. They are gone rather than
/// left to rot: a `catch ConnectionError.connectFailed` that silently stops
/// matching is worse than one that stops compiling, and the two rendered
/// differently anyway (`TransportError` describes itself; this did not).
public enum ConnectionError: Error, Equatable {
    case closed
    case handshakeFailed(String)
    case unexpectedFrame(FrameType)
}

public final class Connection: @unchecked Sendable {
    private let transport: Transport
    private let readFD: Int32
    private let writeFD: Int32
    private let writeLock = NSLock()
    private var readerThread: Thread?
    private let closed = ManagedAtomicFlag()
    /// Signalled when `readLoop` leaves, so `close` can free the descriptors
    /// only once nothing is on them. `Thread` has no join.
    private let readerFinished = DispatchSemaphore(value: 0)

    /// Frames from the server. Finishes when the connection closes.
    public let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation

    /// Why the connection died, when the transport can say — `ssh`'s own
    /// complaint about a host it could not reach. Nil for a unix socket.
    public var failureDescription: String? { transport.failureDescription }

    public init(transport: Transport) {
        self.transport = transport
        self.readFD = transport.readDescriptor
        self.writeFD = transport.writeDescriptor
        var captured: AsyncStream<Frame>.Continuation?
        self.frames = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        // AsyncStream runs its build closure synchronously, so this is set.
        guard let continuation = captured else {
            preconditionFailure("AsyncStream did not provide a continuation")
        }
        self.continuation = continuation
    }

    public convenience init(socketPath: String) throws {
        self.init(transport: try UnixSocketTransport(path: socketPath))
    }

    /// Connect to whichever machine `host` names. This is the only line in the
    /// client that has an opinion about local versus remote.
    public convenience init(host: ServerHost) throws {
        self.init(transport: try host.makeTransport())
    }

    deinit {
        close()
    }

    public func start() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "illogical.connection"
        thread.stackSize = 512 * 1024
        // Recorded *before* the thread runs. Assigned after `start()`, a
        // `close()` racing this read nil, skipped the wait entirely, and freed
        // the descriptors with the reader already inside `read`.
        readerThread = thread
        thread.start()
    }

    /// Tear the connection down, in the one order that is safe.
    ///
    /// `shutdown` breaks the connection while the descriptor numbers are still
    /// ours; they are freed only once the reader has left. Freeing first hands
    /// the number back with a thread still blocked on it, and the next
    /// connection in the process is handed the same number -- one terminal's
    /// keystrokes arriving in another's PTY.
    ///
    /// The waiting happens *off* the caller's thread. `close()` is called from
    /// the main actor, once per pane, and blocking there for a wedged child
    /// froze the window for seconds while closing a split tab. Nothing above
    /// needs to observe the free: `closed` is set synchronously, so every
    /// later `send` already fails.
    public func close() {
        guard closed.testAndSet() == false else { return }
        transport.shutdown()
        continuation.finish()

        // A `Bool`, not the `Thread`: the block only ever asks whether there
        // was a reader, and `Thread` is not `Sendable`, so capturing it is a
        // strict-concurrency warning for nothing.
        let hasReader = readerThread != nil
        readerThread = nil
        let transport = self.transport
        let finished = readerFinished
        let lock = writeLock

        DispatchQueue.global(qos: .utility).async {
            // Deliberately leaked if the reader never comes back: a child that
            // ignores SIGTERM and keeps its inherited write end open means we
            // never see end-of-file, and freeing the number then is the bug
            // this ordering exists to prevent. `shutdown` has already made the
            // descriptor inert.
            if hasReader, finished.wait(timeout: .now() + 2) != .success { return }

            // Under the write lock, so a `send` that was already inside it has
            // finished with the descriptor before the number goes back.
            lock.lock()
            defer { lock.unlock() }
            transport.close()
        }
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
        // Under the lock, and re-checked here rather than at the top: `close`
        // frees the descriptor while holding this same lock, so a `send` that
        // passed an unlocked check could still be handed a number that now
        // belongs to another connection.
        guard !closed.isSet else { throw ConnectionError.closed }
        try frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(
                    writeFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
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
        // Signalled last, and unconditionally: `close` waits on it before it
        // frees the descriptors this loop is reading.
        defer {
            continuation.finish()
            readerFinished.signal()
        }

        var header = [UInt8](repeating: 0, count: Protocol.headerLength)
        while !closed.isSet {
            guard readExact(into: &header, count: Protocol.headerLength) else { break }
            // A frame we cannot parse is not something to keep reading past --
            // the stream is a byte stream, so one bad header means every later
            // offset is wrong. It happens for real: a remote login shell that
            // echoes a line from `.bashrc` puts it ahead of the first frame.
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

        // The far end went, or said something unparseable. Break the transport
        // rather than leaving it: an `ssh` child whose stdin pipe we still hold
        // stays alive, pinning its ControlPersist master and three descriptors,
        // and every reconnect adds another. `shutdown` only -- freeing the
        // numbers is `close`'s job, and this is the thread it waits for.
        transport.shutdown()
    }

    private func readExact(into buf: inout [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = buf.withUnsafeMutableBytes { raw in
                Darwin.read(readFD, raw.baseAddress!.advanced(by: offset), count - offset)
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

/// Body of ``FrameType/renameSession``.
///
/// The session id is in the body rather than the frame header, because that
/// header's u64 addresses a terminal. Sent on the control channel; the server
/// answers a refusal with an `err` there and a success with the
/// `sessions_changed` broadcast every client already re-lists on.
public struct RenameSessionBody: Codable, Sendable {
    public var session: UInt64
    public var name: String

    public init(session: UInt64, name: String) {
        self.session = session
        self.name = name
    }
}

/// Body of ``FrameType/deleteSession``.
public struct DeleteSessionBody: Codable, Sendable {
    public var session: UInt64
    /// Refuse rather than cascade when the session still has terminals. For
    /// scripts that want to be careful; the app always cascades, behind a
    /// confirmation.
    public var onlyIfEmpty: Bool

    enum CodingKeys: String, CodingKey {
        case session
        case onlyIfEmpty = "only_if_empty"
    }

    public init(session: UInt64, onlyIfEmpty: Bool = false) {
        self.session = session
        self.onlyIfEmpty = onlyIfEmpty
    }
}

public struct ErrBody: Codable, Sendable {
    public var code: UInt16
    public var message: String
}

public struct ExitedBody: Codable, Sendable {
    public var code: Int32
}
