//  Transport.swift
//  What a Connection reads and writes, and nothing above it knows which.
//
//  Two of them:
//
//      local    a unix socket, one descriptor for both directions
//      remote   `ssh <dest> illogicald --stdio`, a pipe each way
//
//  That is the whole of the remote story on this side. No TLS, no listening
//  socket, no credential handling of ours: the user's existing SSH config,
//  keys, jump hosts and agent forwarding decide who may connect, and the far
//  end is src/daemon/stdio.zig splicing the pipe onto that host's own unix
//  socket. See docs/PROTOCOL.md, "Transport".

import Darwin
import Foundation

/// A pair of descriptors carrying the wire protocol, and whatever is holding
/// them open.
///
/// Teardown is deliberately two steps, and the split is the whole reason this
/// is a protocol rather than a descriptor pair. Freeing a descriptor hands its
/// *number* straight back to the kernel, and the next `socket()` or `pipe()` in
/// the process gets it — so a reader still blocked on the old number, or a
/// writer that raced the close, reads and writes some other connection's
/// terminal. `shutdown()` breaks the connection while the numbers are still
/// ours; `close()` frees them, and only once nothing is using them.
public protocol Transport: AnyObject, Sendable {
    /// Frames are read from here.
    var readDescriptor: Int32 { get }
    /// Frames are written here. The same descriptor for a socket.
    var writeDescriptor: Int32 { get }

    /// Break the connection so a blocked read returns, *without* freeing the
    /// descriptors. Idempotent, and safe to call from another thread.
    func shutdown()

    /// Free the descriptors. The caller must have finished `shutdown()` and
    /// established that nothing is still reading or writing them. Idempotent.
    func close()

    /// Why the transport died, when it died on its own — `ssh` refusing a host
    /// key, or a remote machine with no `illogicald` on its PATH. Nil for a
    /// unix socket, which has nothing to say that `errno` did not, and nil
    /// while the connection is still up.
    var failureDescription: String? { get }
}

public enum TransportError: Error, Equatable, CustomStringConvertible {
    case socketFailed(Int32)
    case connectFailed(Int32)
    case pathTooLong
    case notOnPath(String)
    case spawnFailed(String)

    /// Read by a person, in the session dropdown, next to the host that failed.
    /// `Error`'s own rendering of these is `NSCocoaErrorDomain` noise.
    public var description: String {
        switch self {
        case .socketFailed(let code): "could not open a socket (\(code))"
        case .connectFailed(let code): "could not connect (\(code))"
        case .pathTooLong: "the socket path is too long"
        case .notOnPath(let command): "\(command) is not on PATH"
        case .spawnFailed(let detail): detail
        }
    }
}

// MARK: - Local

/// A unix domain socket. One descriptor, both directions.
public final class UnixSocketTransport: Transport, @unchecked Sendable {
    private let fd: Int32
    private let shutdownFlag = ManagedAtomicFlag()
    private let closedFlag = ManagedAtomicFlag()

    public var readDescriptor: Int32 { fd }
    public var writeDescriptor: Int32 { fd }
    public var failureDescription: String? { nil }

    public init(path: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            throw TransportError.pathTooLong
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
            throw TransportError.connectFailed(code)
        }
        self.fd = fd
    }

    deinit {
        shutdown()
        close()
    }

    /// Wakes a blocked reader while the descriptor number is still ours.
    public func shutdown() {
        guard shutdownFlag.testAndSet() == false else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    public func close() {
        guard closedFlag.testAndSet() == false else { return }
        Darwin.close(fd)
    }
}

// MARK: - Remote

/// A child process with pipes on its standard input and output. Used for
/// exactly one thing: `ssh <dest> illogicald --stdio`.
public final class CommandTransport: Transport, @unchecked Sendable {
    private let process: Process
    private let toChild: FileHandle
    private let fromChild: FileHandle
    /// Held so `close` can free it promptly, rather than whenever the drain
    /// thread happens to end.
    ///
    /// The read end of the child's stderr used to leak one descriptor per
    /// transport for the life of the process: the dispatch source behind the
    /// `readabilityHandler` this drain replaced kept the `FileHandle` alive
    /// past its owner, so nothing ever closed it. One connection per terminal
    /// means a window that opens and closes remote panes walks to `EMFILE`, at
    /// which point even a local unix socket stops connecting.
    ///
    /// The drain closure retains this handle too, and `Pipe` builds its
    /// handles with `closeOnDealloc`, so the descriptor does come back on its
    /// own once the drain ends. That is the safety net under `close`'s
    /// timeout, not the mechanism: a finished drain is what makes closing here
    /// *safe*, and closing here is what makes it *prompt*.
    private let stderrHandle: FileHandle
    private let shutdownFlag = ManagedAtomicFlag()
    private let closedFlag = ManagedAtomicFlag()
    /// Signalled when the stderr drain thread reaches end-of-file, so `close`
    /// frees that descriptor only once nothing is reading it.
    private let drainFinished = DispatchSemaphore(value: 0)

    /// The child's stderr, kept so a failure can say what the child said. SSH
    /// reports a bad host key, an unreachable host and a missing binary there,
    /// and those are the three things that actually go wrong.
    private let diagnostics = Diagnostics()

    public let readDescriptor: Int32
    public let writeDescriptor: Int32

    /// What the child said, but only once it has actually gone.
    ///
    /// Gated on the process, not merely on there being output: `ssh` writes
    /// plenty to stderr on a perfectly good connection — "Permanently added
    /// 'build-box' to the list of known hosts" on the first connect, banners,
    /// and the remote daemon's own logging. Reporting any of that made a
    /// healthy host render as the one that failed.
    public var failureDescription: String? {
        guard !process.isRunning else { return nil }
        let text = diagnostics.text
        return text.isEmpty ? nil : text
    }

    /// Whether the child is still running. A `false` here with the connection
    /// still open means `ssh` gave up, and `failureDescription` says why.
    public var isRunning: Bool { process.isRunning }

    public init(argv: [String]) throws {
        guard let executable = argv.first else {
            throw TransportError.spawnFailed("no command")
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = try Self.resolve(executable)
        process.arguments = Array(argv.dropFirst())
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw TransportError.spawnFailed("\(error)")
        }

        self.process = process
        self.toChild = stdinPipe.fileHandleForWriting
        self.fromChild = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        self.readDescriptor = stdoutPipe.fileHandleForReading.fileDescriptor
        self.writeDescriptor = stdinPipe.fileHandleForWriting.fileDescriptor

        // Drained rather than merely captured. An undrained stderr pipe fills
        // at 64 KiB and blocks the child inside a write, and a wedged `ssh` is
        // indistinguishable from a slow network.
        //
        // A thread rather than a `readabilityHandler`, for the same reason the
        // frame reader is one: a dispatch source cannot be *joined*. Clearing
        // the handler does not wait for a block already running, so closing
        // the descriptor under it either raised an uncatchable ObjC exception
        // or -- once the number was recycled -- appended another connection's
        // bytes to this one's diagnostics. It also read to EOF only when it
        // felt like it, so closing could discard the very message this exists
        // to capture.
        let sink = diagnostics
        let handle = stderrPipe.fileHandleForReading
        let finished = drainFinished
        let drain = Thread {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                sink.append(data)
            }
            finished.signal()
        }
        drain.name = "illogical.stderr"
        drain.stackSize = 128 * 1024
        drain.start()
    }

    /// Find `command` the way a shell would.
    ///
    /// `Process` does not do this: `executableURL` is a *path*, and a bare
    /// `ssh` is resolved against the current directory, which for a .app is
    /// wherever it happened to be launched from. So `ssh` failed with "the
    /// file ssh doesn't exist" and the host looked unreachable.
    ///
    /// The `PATH` a bundle inherits from Finder is the minimal one, which does
    /// contain `/usr/bin`; the fallback below is that same list, for a launch
    /// context that passes no `PATH` at all.
    static func resolve(_ command: String) throws -> URL {
        if command.contains("/") { return URL(fileURLWithPath: command) }
        let path =
            ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appending(path: command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw TransportError.notOnPath(command)
    }

    deinit {
        shutdown()
        close()
    }

    /// How long the stderr drain gets to reach end-of-file before its
    /// descriptor is left to `closeOnDealloc`.
    ///
    /// Long enough to be a process's exit rather than a thread's wakeup, which
    /// is what it has to cover: `shutdown` only sends SIGTERM, and the case it
    /// exists for is precisely a child that does not take it — `ssh` holding a
    /// ControlPersist master, or anything with a `trap`. EOF on this pipe
    /// needs every copy of its write end closed, so it waits on the child, not
    /// on the reader.
    private static let drainGrace: TimeInterval = 1

    /// A pipe has no `shutdown(2)`, so the equivalent is to stop the thing on
    /// the other end of it: the child exiting closes its ends, our reader sees
    /// end-of-file, and the descriptor numbers stay ours throughout.
    ///
    /// `ssh` holding a control master can outlive its own session, so
    /// end-of-file on its stdin is not enough to be sure it goes.
    public func shutdown() {
        guard shutdownFlag.testAndSet() == false else { return }
        if process.isRunning { process.terminate() }
    }

    public func close() {
        guard closedFlag.testAndSet() == false else { return }
        // No wait for the child. Closing *our* end frees *our* descriptor
        // number; whether the child still holds its twin is the kernel's
        // business, not ours. The only thing that must be ordered is our own
        // threads, and the caller has already seen the frame reader out.
        try? toChild.close()
        try? fromChild.close()

        // Stderr is ours to order, though: its drain thread is reading that
        // descriptor, and closing a `FileHandle` out from under a live
        // `readDataUpToLength:` is not a soft failure. Foundation raises an
        // ObjC exception on the *reading* thread, which `try?` cannot catch,
        // and the process aborts. Making this unconditional takes the test
        // bundle down with SIGABRT inside
        // `-[NSConcreteFileHandle readDataUpToLength:error:]` -- so this wait
        // is load-bearing, not a tidiness measure.
        //
        // Not a permanent leak when it times out: the drain closure holds the
        // last reference to a `Pipe` handle, which closes on dealloc, so the
        // descriptor comes back when the child finally goes and the read
        // returns. This branch is what makes it prompt in the ordinary case,
        // where the child is already gone.
        if drainFinished.wait(timeout: .now() + Self.drainGrace) == .success {
            try? stderrHandle.close()
        }
    }
}

/// A bounded tail of a child's stderr.
private final class Diagnostics: @unchecked Sendable {
    /// Enough for ssh's longest complaint — the host-key warning is about
    /// twenty lines — and bounded so a remote command that prints forever
    /// cannot grow this without limit.
    private static let limit = 8 * 1024

    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > Self.limit {
            buffer.removeFirst(buffer.count - Self.limit)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The ssh command

/// How the client invokes `ssh`.
///
/// This must stay in step with `conn.Ssh` in src/core/conn.zig — deliberately,
/// and not only for tidiness: both render the same `ControlPath`, so the app
/// and the CLI share one multiplexing master and the second of them to connect
/// pays for a channel rather than a handshake.
public enum SSHCommand {
    /// Seconds between keepalives, and how many may go unanswered. Together
    /// they are how long a dead network takes to become a *closed connection*,
    /// which is what the client turns into a reconnect. Without them a laptop
    /// that changed networks waits forever on a socket with nobody behind it.
    static let aliveInterval = "15"
    static let aliveCountMax = "3"
    /// How long the multiplexing master lingers after the last connection, so
    /// closing a window and opening another does not re-authenticate.
    static let controlPersist = "60"

    /// A unix socket path has about 104 bytes and OpenSSH renders `%C` as a
    /// 40-character hash. Past this, ask for no multiplexing rather than have
    /// ssh warn about a path it cannot bind on every single connection.
    static let controlBudget = 100

    public struct Options: Hashable, Sendable {
        public var destination: String
        /// The daemon to run on the far side, resolved by the login shell's
        /// PATH there.
        public var remoteBinary: String
        /// The `ssh` to run. A field so a test can stand in for it.
        public var ssh: String
        /// Where the multiplexing socket goes. Nil asks for `~/.ssh`.
        public var controlDirectory: String?
        /// One SSH connection per terminal is what multiplexing avoids, and a
        /// window with four splits opens five.
        public var multiplex: Bool

        public init(
            destination: String,
            remoteBinary: String = "illogicald",
            ssh: String = "ssh",
            controlDirectory: String? = nil,
            multiplex: Bool = true
        ) {
            self.destination = destination
            self.remoteBinary = remoteBinary
            self.ssh = ssh
            self.controlDirectory = controlDirectory
            self.multiplex = multiplex
        }
    }

    public static func argv(_ options: Options) -> [String] {
        var argv = [
            options.ssh,
            // No pty. A pty would put a line discipline in the middle of a
            // binary frame stream and translate every 0x0a byte it carried.
            "-T",
            "-o", "ServerAliveInterval=\(aliveInterval)",
            "-o", "ServerAliveCountMax=\(aliveCountMax)",
        ]

        if options.multiplex, let path = controlPath(options) {
            argv += ["-o", "ControlMaster=auto"]
            argv += ["-o", "ControlPath=\(path)"]
            argv += ["-o", "ControlPersist=\(controlPersist)"]
        }

        // `--` first. Without it a destination beginning with `-` is parsed by
        // ssh as an option: `-weirdhost` becomes `-w eirdhost` and fails with
        // "Bad tun device". Nothing reachable gets further than a usage dump
        // today, but a destination is user input in an option slot, and
        // `-oProxyCommand=` is what that slot is one argument away from.
        argv.append("--")
        argv.append(options.destination)
        // ssh joins what follows with spaces and hands it to the login shell,
        // which is what resolves `illogicald` on the far side.
        argv.append(options.remoteBinary)
        argv.append("--stdio")
        return argv
    }

    /// The `ControlPath` template, or nil when there is nowhere short enough to
    /// put it.
    ///
    /// `$HOME`, not `homeDirectoryForCurrentUser` — the latter reads the passwd
    /// entry and ignores the environment, so the two disagree whenever `$HOME`
    /// is overridden. `src/core/conn.zig` uses `getenv("HOME")`, and the pairing
    /// only buys anything if both render the *same* path: disagree and the app
    /// and `illogical --host` bind different control sockets and hold two ssh
    /// masters, which is precisely what this exists to avoid. Nil when `$HOME`
    /// is unset, which is what the Zig side does too.
    static func controlPath(_ options: Options) -> String? {
        let directory: String
        if let explicit = options.controlDirectory {
            directory = explicit
        } else {
            guard let home = ProcessInfo.processInfo.environment["HOME"] else { return nil }
            directory = home + "/.ssh"
        }
        let path = directory + "/illogical-%C"
        // `%C` is two characters here and forty at render time.
        guard path.utf8.count - 2 + 40 <= controlBudget else { return nil }
        return path
    }

    /// Make sure the directory the control socket goes in exists.
    ///
    /// `ssh` creates the socket but not the directory above it, so on a machine
    /// whose owner has never run ssh, multiplexing would fail on every
    /// connection with nothing to show for it.
    static func prepareControlDirectory(_ options: Options) {
        guard options.multiplex, let path = controlPath(options) else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
