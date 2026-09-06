//  TransportTests.swift
//  The two ways a client reaches a daemon.
//
//  The ssh command is asserted argument by argument on purpose. Every option in
//  it is load-bearing — `-T` keeps a line discipline out of a binary stream,
//  the keepalives are what turn a dead network into a reconnect — and none of
//  them fail loudly if they go missing.

import Darwin
import Foundation
import Testing

@testable import IllogicalProtocol

@Suite("The ssh command")
struct SSHCommandTests {
    private func argv(
        _ destination: String = "build-box",
        remoteBinary: String = "illogicald",
        controlDirectory: String? = "/tmp",
        multiplex: Bool = true
    ) -> [String] {
        SSHCommand.argv(
            SSHCommand.Options(
                destination: destination,
                remoteBinary: remoteBinary,
                controlDirectory: controlDirectory,
                multiplex: multiplex))
    }

    @Test("ends in the remote daemon, in stdio mode")
    func shape() {
        let args = argv()
        #expect(args.first == "ssh")
        // ssh takes the first non-option as the host and everything after it
        // as the command, so these three are last and in this order.
        #expect(args.suffix(3) == ["build-box", "illogicald", "--stdio"])
    }

    @Test("asks for no pty")
    func noPTY() {
        // Not a preference. A pty would put a line discipline in the middle of
        // the frame stream and rewrite every 0x0a byte a snapshot chunk
        // carried.
        #expect(argv().contains("-T"))
    }

    @Test("asks for keepalives, so a dead network closes rather than hangs")
    func keepalives() {
        let args = argv()
        #expect(args.contains("ServerAliveInterval=15"))
        #expect(args.contains("ServerAliveCountMax=3"))
    }

    @Test("multiplexes, so a split costs a channel rather than a handshake")
    func multiplexing() {
        let args = argv()
        #expect(args.contains("ControlMaster=auto"))
        #expect(args.contains("ControlPath=/tmp/illogical-%C"))
        #expect(args.contains("ControlPersist=60"))
        // Every `-o` introduces exactly one option.
        #expect(args.filter { $0 == "-o" }.count == 5)
    }

    @Test("multiplexing can be turned off")
    func noMultiplexing() {
        let args = argv(multiplex: false)
        #expect(!args.contains("ControlMaster=auto"))
        #expect(args.filter { $0 == "-o" }.count == 2)
        #expect(args.suffix(3) == ["build-box", "illogicald", "--stdio"])
    }

    @Test("a control path that would not fit a unix socket is not asked for")
    func controlPathBudget() {
        // The shape a macOS TMPDIR has: deep enough that the rendered hash
        // pushes the socket name past what `bind` accepts. ssh would warn
        // about it on every connection and fall back anyway.
        let deep = "/var/folders/2b/" + String(repeating: "x", count: 48) + "/T"
        let args = argv(controlDirectory: deep)
        #expect(!args.contains("ControlMaster=auto"))
        #expect(args.suffix(3) == ["build-box", "illogicald", "--stdio"])
    }

    @Test("a remote binary somewhere else is respected")
    func remoteBinary() {
        let args = argv("me@host", remoteBinary: "/opt/illogical/bin/illogicald")
        #expect(args.suffix(3) == ["me@host", "/opt/illogical/bin/illogicald", "--stdio"])
    }

    /// The Zig CLI renders the same path, so `illogical --host` and the app
    /// share one multiplexing master. Drifting apart would silently double the
    /// SSH connections a machine holds.
    @Test("the default control path is the one src/core/conn.zig renders")
    func defaultControlPath() {
        let path = SSHCommand.controlPath(SSHCommand.Options(destination: "h"))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(path == home + "/.ssh/illogical-%C")
    }
}

@Suite("Transports")
struct TransportTests {
    /// `cat` is the smallest thing that behaves like the far end of an SSH
    /// pipe: what goes in comes back, framed exactly as it was sent. The
    /// transport is what is under test, not the server.
    @Test("a command transport round-trips a frame larger than a pipe buffer")
    func commandRoundTrip() async throws {
        let transport = try CommandTransport(argv: ["/bin/cat"])
        let connection = Connection(transport: transport)
        connection.start()
        defer { connection.close() }

        // Bigger than the 64 KiB a pipe holds, so a transport that lost track
        // of a partial write would truncate it.
        var payload = Data(count: 128 * 1024)
        for i in payload.indices { payload[i] = UInt8(truncatingIfNeeded: i &* 17) }
        try connection.send(.input, terminal: 42, payload: payload)

        var received: Frame?
        for await frame in connection.frames {
            received = frame
            break
        }
        let frame = try #require(received)
        #expect(frame.type == .input)
        #expect(frame.terminal == 42)
        #expect(frame.payload == payload)
    }

    @Test("a command that fails says why")
    func commandFailureIsReported() async throws {
        // Something that is definitely on every macOS, and definitely
        // complains: `ssh` failing to resolve a host looks the same from here.
        let transport = try CommandTransport(argv: ["/bin/sh", "-c", "echo nope >&2; exit 3"])
        let connection = Connection(transport: transport)
        connection.start()
        defer { connection.close() }

        // The stream finishes when the child's stdout closes.
        for await _ in connection.frames {}

        // The message arrives on a readability handler, so give it the moment
        // it needs rather than racing it.
        for _ in 0..<100 where connection.failureDescription == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.failureDescription == "nope")
    }

    @Test("closing a command transport is idempotent and stops the child")
    func closeIsIdempotent() throws {
        let transport = try CommandTransport(argv: ["/bin/cat"])
        #expect(transport.isRunning)
        transport.close()
        transport.close()

        for _ in 0..<200 where transport.isRunning {
            usleep(10_000)
        }
        #expect(!transport.isRunning)
    }

    /// `Process.executableURL` is a path, not a command: a bare `ssh` resolves
    /// against the *current directory*, which for a .app is wherever Finder
    /// launched it from. Without this the only remote host anyone would ever
    /// configure fails with "the file ssh doesn't exist".
    @Test("a bare command name is resolved against PATH, the way a shell would")
    func resolvesOnPath() throws {
        // Not compared against a literal: which `sh` is first on PATH is the
        // environment's business — inside `nix develop` it is not /bin/sh.
        // What has to hold is that a bare name comes back absolute, executable
        // and still itself.
        let resolved = try CommandTransport.resolve("sh")
        #expect(resolved.path.hasPrefix("/"))
        #expect(resolved.lastPathComponent == "sh")
        #expect(FileManager.default.isExecutableFile(atPath: resolved.path))

        // A path stays exactly the path it was.
        #expect(try CommandTransport.resolve("/bin/cat").path == "/bin/cat")

        #expect(throws: TransportError.notOnPath("illogical-no-such-command")) {
            _ = try CommandTransport.resolve("illogical-no-such-command")
        }
    }

    /// These end up in the session dropdown next to the host that failed, so
    /// they have to read like something a person wrote.
    @Test("transport errors say what happened without NSCocoaErrorDomain in it")
    func errorsAreReadable() {
        #expect(String(describing: TransportError.notOnPath("ssh")) == "ssh is not on PATH")
        #expect(String(describing: TransportError.pathTooLong) == "the socket path is too long")
    }

    @Test("a unix socket transport reports a path that is not there")
    func missingSocket() {
        #expect(throws: TransportError.self) {
            _ = try UnixSocketTransport(path: "/tmp/illogical-does-not-exist-\(getpid()).sock")
        }
    }

    @Test("a socket path longer than sockaddr_un is refused, not truncated")
    func pathTooLong() {
        #expect(throws: TransportError.pathTooLong) {
            _ = try UnixSocketTransport(path: "/tmp/" + String(repeating: "x", count: 200))
        }
    }

    /// A write to a socket whose far end has gone raises SIGPIPE, and the
    /// default disposition for that kills the process. A daemon going away
    /// with a keystroke in flight is exactly what reconnecting is for, so
    /// without `SO_NOSIGPIPE` the recovery path is the one that kills the app,
    /// taking every other pane's window with it.
    ///
    /// This test passing at all is most of the assertion: a regression here
    /// does not fail, it terminates the test runner.
    @Test("a write to a socket whose peer has gone throws instead of killing us")
    func writeAfterPeerHungUp() throws {
        let path = "/tmp/illogical-sigpipe-\(getpid()).sock"
        unlink(path)
        defer { unlink(path) }

        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(listener) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(listener, 1) == 0)

        let connection = Connection(transport: try UnixSocketTransport(path: path))
        defer { connection.close() }
        let accepted = Darwin.accept(listener, nil, nil)
        try #require(accepted >= 0)
        Darwin.close(accepted)

        // The first write after the peer goes usually lands in the socket
        // buffer and succeeds; EPIPE arrives on a later one.
        var threw = false
        for _ in 0..<64 where !threw {
            do {
                try connection.send(.input, terminal: 1, payload: Data(count: 64 * 1024))
            } catch {
                threw = true
            }
        }
        #expect(threw, "a dead socket took four megabytes without complaint")
    }

    /// A host round-trips through the defaults the window stores it in.
    @Test("a remote host survives being written down")
    func hostCoding() throws {
        let host = ServerHost.ssh(destination: "me@build-box", remoteBinary: "illogicald")
        let data = try JSONEncoder().encode(host)
        #expect(try JSONDecoder().decode(ServerHost.self, from: data) == host)
        #expect(host.displayName == "me@build-box")
        #expect(host.isRemote)
        #expect(!ServerHost.local(socketPath: "/tmp/s").isRemote)
    }
}
