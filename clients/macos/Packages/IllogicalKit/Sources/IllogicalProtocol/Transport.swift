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
    /// When `close`'s wait times out this descriptor is left alone and
    /// `closeOnDealloc` is what eventually frees it -- once *all three* holders
    /// let go: this property, the `Pipe` reachable through
    /// `process.standardError`, and the drain closure. So the bound is the
    /// later of "the caller released the transport" and "the drain returned".
    /// For the one caller in this tree it is the *transport*: `Connection`
    /// holds it in a `let` it never clears, and `failureDescription` reads
    /// that same stored transport, so `close()` returning frees nothing. On
    /// its two-second-timeout path it does not even call `transport.close()`.
    /// A model object that keeps closed `Connection`s therefore keeps one
    /// stderr descriptor per closed remote pane, which is the walk to `EMFILE`
    /// this doc opens with.
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
    /// This is a bound on how long `close` may block, not a prediction of when
    /// the child dies -- and the difference matters, because it cannot be the
    /// latter. EOF here needs every copy of the write end closed, so it waits
    /// on the *process*; `shutdown` only sends SIGTERM; and the cases that
    /// motivated the wait are a `ControlPersist` master (60s) and a child with
    /// a `trap` (this suite's is 2s). One second covers neither, deliberately.
    /// It buys the common case -- a child already gone, needing only the
    /// drain's wakeup -- and gives up rather than hanging the caller for the
    /// uncommon one.
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
        // `readDataUpToLength:` has two outcomes, both bad. If the number is
        // still free the next read raises an ObjC exception on the *reading*
        // thread, which no `try?` here can catch, and the process aborts --
        // making this unconditional takes the test bundle down with SIGABRT
        // inside `-[NSConcreteFileHandle readDataUpToLength:error:]`. If
        // another pane's `Pipe` has taken the number first, the read simply
        // succeeds and appends that pane's stderr to this one's diagnostics,
        // which is the same fd-recycling hazard the whole shutdown/close split
        // exists for. The loud one is what a test sees; the quiet one is what
        // a user sees.
        //
        // Not a permanent leak when it times out, but not prompt either.
        // `Pipe` handles close on dealloc and three things hold this one --
        // the stored property, the `Pipe` under `process.standardError`, and
        // the drain closure -- so the descriptor comes back on the *later* of
        // the transport being released and the drain returning. This line is
        // what makes the ordinary case, where the child is already gone,
        // immediate instead.
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
    // And deliberately *no* `ConnectTimeout`. It is the obvious companion to
    // these -- without one a black-holed host sits in the TCP connect for the
    // platform default, about 75 seconds on macOS -- but it also bounds the
    // banner exchange, and behind a `ProxyJump` the target's banner cannot
    // arrive until the whole inner hop has authenticated. So a bastion that
    // wants a hardware-key touch or a push gets however long we set, and no
    // longer: measured, `ConnectTimeout=2` against a proxy ready at 3s fails
    // at 2.009s with "Connection timed out during banner exchange". A
    // command-line `-o` beats the user's own ssh_config, so there would be no
    // way to opt back out. Jump hosts are part of the config this client
    // exists to inherit; a slow first paint is the better failure.
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
    /// Takes the *environment* rather than a home directory, and that is the
    /// point. `src/core/conn.zig:291` renders this same path from
    /// `getenv("HOME")`; a client that read the passwd entry instead — via
    /// `homeDirectoryForCurrentUser`, the obvious-looking alternative — would
    /// disagree whenever `$HOME` is overridden, and the app and `illogical
    /// --host` would bind different control sockets and hold two ssh masters
    /// per host. That pairing is the whole reason this function exists.
    ///
    /// The two sources agree on every machine anyone tests on, so no assertion
    /// can tell them apart without an input the test chooses. Four earlier
    /// versions tried to *detect* the substitution and each was a tautology in
    /// a new place — the expectation computed the same way the code computed
    /// the value, and once a parameter was added, the tautology moved into its
    /// default. Setting `HOME` for real does work, and puts a write to
    /// `environ` beside suites that walk it. Taking the dictionary makes the
    /// mistake unrepresentable instead: there is nowhere to put
    /// `homeDirectoryForCurrentUser` that type-checks.
    ///
    /// Nil when `HOME` is absent, which is what the Zig side does too.
    static func controlPath(
        _ options: Options,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let directory: String
        if let explicit = options.controlDirectory {
            directory = explicit
        } else {
            guard let home = environment["HOME"] else { return nil }
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
