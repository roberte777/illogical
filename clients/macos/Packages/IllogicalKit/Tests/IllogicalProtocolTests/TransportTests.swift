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
        ssh: String = "ssh",
        controlDirectory: String? = "/tmp",
        multiplex: Bool = true
    ) -> [String] {
        SSHCommand.argv(
            SSHCommand.Options(
                destination: destination,
                remoteBinary: remoteBinary,
                ssh: ssh,
                controlDirectory: controlDirectory,
                multiplex: multiplex))
    }

    @Test("ends in the remote daemon, in stdio mode")
    func shape() {
        let args = argv()
        #expect(args.first == "ssh")
        // ssh takes the first non-option as the host and everything after it
        // as the command, so these three are last and in this order.
        #expect(args.suffix(4) == ["--", "build-box", "illogicald", "--stdio"])
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
        // And the one for the connection that has not happened yet: without it
        // a black-holed host sits in the TCP connect for ~75s on macOS, which
        // the client spends showing nothing wrong at all.
        #expect(args.contains("ConnectTimeout=10"))
    }

    @Test("multiplexes, so a split costs a channel rather than a handshake")
    func multiplexing() {
        let args = argv()
        #expect(args.contains("ControlMaster=auto"))
        #expect(args.contains("ControlPath=/tmp/illogical-%C"))
        #expect(args.contains("ControlPersist=60"))
        // Every `-o` introduces exactly one option.
        #expect(args.filter { $0 == "-o" }.count == 6)
    }

    @Test("multiplexing can be turned off")
    func noMultiplexing() {
        let args = argv(multiplex: false)
        #expect(!args.contains("ControlMaster=auto"))
        #expect(args.filter { $0 == "-o" }.count == 3)
        #expect(args.suffix(4) == ["--", "build-box", "illogicald", "--stdio"])
    }

    @Test("a control path that would not fit a unix socket is not asked for")
    func controlPathBudget() {
        // The shape a macOS TMPDIR has: deep enough that the rendered hash
        // pushes the socket name past what `bind` accepts. ssh would warn
        // about it on every connection and fall back anyway.
        let deep = "/var/folders/2b/" + String(repeating: "x", count: 48) + "/T"
        let args = argv(controlDirectory: deep)
        #expect(!args.contains("ControlMaster=auto"))
        #expect(args.suffix(4) == ["--", "build-box", "illogicald", "--stdio"])
    }

    @Test("a remote binary somewhere else is respected")
    func remoteBinary() {
        let args = argv("me@host", remoteBinary: "/opt/illogical/bin/illogicald")
        #expect(args.suffix(4) == ["--", "me@host", "/opt/illogical/bin/illogicald", "--stdio"])
    }

    /// The Zig CLI renders the same path, so `illogical --host` and the app
    /// share one multiplexing master. Drifting apart silently doubles the SSH
    /// connections a machine holds.
    ///
    /// Asserted against `$HOME` explicitly, not against whatever API the
    /// implementation happens to call. Computing the expectation the same way
    /// the code does made this tautological: it stayed green while the two
    /// languages derived home differently, which is exactly the bug it is named
    /// for. `src/core/conn.zig` uses `getenv("HOME")`.
    @Test("the default control path is the one src/core/conn.zig renders")
    func defaultControlPath() throws {
        let home = try #require(ProcessInfo.processInfo.environment["HOME"])
        let path = SSHCommand.controlPath(SSHCommand.Options(destination: "h"))
        #expect(path == home + "/.ssh/illogical-%C")
        // And `homeDirectoryForCurrentUser` is *not* what we use: it reads the
        // passwd entry and ignores the environment.
        #expect(!home.isEmpty)
    }

    @Test("the ssh binary can be overridden")
    func sshOverride() {
        // ILLOGICAL_SSH rides through `ServerHost.sshOptions`; without this the
        // override could be dropped from the argv with nothing failing, and a
        // user with a second OpenSSH would silently get the first on PATH.
        #expect(argv(ssh: "/usr/bin/ssh").first == "/usr/bin/ssh")
    }
}

/// Serialized, because three of these hold a child process — and its three
/// descriptors — across an `await`, and `noDescriptorLeak` counts descriptors
/// *process-wide*. Run concurrently, a spawn landing inside its five-millisecond
/// sampling window is a +3 it reads as a leak. Waiting the children out at the
/// end of their own tests does not fix that: the descriptors are freed
/// asynchronously when the child exits, so the overlap is with the spawn, not
/// with the teardown.
@Suite("Transports", .serialized)
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

        // Bigger than the 64 KiB a pipe holds, so the *read* side has to
        // reassemble across many `read` calls. It does not exercise a partial
        // write: `write(2)` on a blocking pipe returns the full count or
        // blocks, so `send`'s loop cannot come up short here.
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

        // The message arrives on the drain thread, which is not synchronised
        // with the frame stream ending, so give it the moment it needs rather
        // than racing it.
        for _ in 0..<100 where connection.failureDescription == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.failureDescription == "nope")
    }

    /// A child that *ignores* stdin end-of-file, which is the case
    /// `shutdown()`'s comment exists for: `ssh` holding a ControlPersist master
    /// outlives its own session. Against `/bin/cat` this test could not fail —
    /// cat exits on EOF whether or not anything terminates it — so the one
    /// behaviour the comment justifies went unasserted.
    @Test("shutdown stops a child that would not leave on end-of-file")
    func shutdownStopsAStubbornChild() throws {
        let transport = try CommandTransport(argv: ["/bin/sh", "-c", "trap '' HUP; sleep 30"])
        #expect(transport.isRunning)
        transport.shutdown()
        for _ in 0..<300 where transport.isRunning { usleep(10_000) }
        #expect(!transport.isRunning)
        transport.close()
    }

    @Test("closing a command transport is idempotent")
    func closeIsIdempotent() throws {
        let transport = try CommandTransport(argv: ["/bin/cat"])
        #expect(transport.isRunning)
        transport.shutdown()
        transport.shutdown()
        transport.close()
        // The second one must be a no-op rather than the same work again. It
        // is not merely wasteful: the drain semaphore has already been
        // consumed, so an unguarded second `close` waits out the whole
        // `drainGrace` before giving up -- a second of it, per pane, on the
        // main actor's teardown path.
        let start = Date()
        transport.close()
        #expect(
            Date().timeIntervalSince(start) < 0.2,
            "a second close did the work again")

        // Polled, like every other `isRunning` assertion in this file. `close`
        // used to spin on this itself, which is the only reason a bare read
        // was ever safe; it now waits on the stderr drain instead. EOF on that
        // pipe and Foundation flipping `isRunning` are two independent
        // consequences of the child exiting -- the kernel wakes the blocked
        // read during `proc_exit`, Foundation notices on a dispatch source of
        // its own -- with no ordering between them, so a bare read loses the
        // race whenever the drain wins by the microseconds it usually does.
        for _ in 0..<300 where transport.isRunning { usleep(10_000) }
        #expect(!transport.isRunning)
    }

    /// One descriptor per transport leaked, unconditionally, because nothing
    /// held the stderr read end — the dispatch source behind the
    /// `readabilityHandler` the drain thread replaced kept it alive past its
    /// owner. One connection per terminal means a window that opens and closes
    /// remote panes walks to `EMFILE`, after which even a local socket stops
    /// connecting.
    ///
    /// Counts descriptors process-wide, so any test that leaves a child alive
    /// past its own body can fail this one instead of itself. Every test here
    /// that spawns a stubborn child waits it out for that reason.
    @Test("a transport gives every descriptor back")
    func noDescriptorLeak() throws {
        func openCount() -> Int {
            (0..<256).filter { fcntl($0, F_GETFD) != -1 }.count
        }
        // One warm-up: the first Process/dispatch use allocates machinery that
        // is not per-transport and would read as a leak.
        let warm = try CommandTransport(argv: ["/bin/cat"])
        warm.shutdown()
        warm.close()

        let before = openCount()
        for _ in 0..<12 {
            let t = try CommandTransport(argv: ["/bin/cat"])
            t.shutdown()
            t.close()
        }
        // Twelve cycles leaked twelve descriptors before the stderr handle was
        // held and closed. A little slack for allocator noise, far below 12.
        #expect(openCount() - before <= 2)
    }

    /// ssh writes to stderr on perfectly good connections — the known-hosts
    /// warning on a first connect, banners, the remote daemon's own logging.
    /// Reporting any of it made a healthy host render as the failed one.
    @Test("a live child's chatter is not a failure")
    func chatterIsNotFailure() async throws {
        let transport = try CommandTransport(
            argv: ["/bin/sh", "-c", "echo 'Warning: Permanently added host' >&2; sleep 30"])
        defer {
            transport.shutdown()
            transport.close()
        }
        for _ in 0..<100 where transport.failureDescription == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transport.isRunning)
        #expect(transport.failureDescription == nil)
    }

    @Test("the control directory is created when it is missing")
    func controlDirectoryIsPrepared() throws {
        // ssh creates the socket but not the directory above it, so on a
        // machine whose owner never ran ssh multiplexing would fail on every
        // connection with nothing to show for it.
        // Short on purpose. A macOS temp directory is ~48 characters before the
        // name, which puts the rendered ControlPath past the 104-byte socket
        // budget — and `prepareControlDirectory` then correctly declines to
        // create anything, so a long path here tests the wrong branch.
        let base = "/tmp/il-\(getpid())-\(UInt32.random(in: 0..<100_000))"
        defer { try? FileManager.default.removeItem(atPath: base) }
        #expect(!FileManager.default.fileExists(atPath: base))

        SSHCommand.prepareControlDirectory(
            SSHCommand.Options(destination: "h", controlDirectory: base))

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: base, isDirectory: &isDir))
        #expect(isDir.boolValue)
        let mode = try FileManager.default.attributesOfItem(atPath: base)[.posixPermissions]
        #expect((mode as? NSNumber)?.int16Value == 0o700)
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

    /// A spawn failure is two different events wearing one name, and the whole
    /// retry decision hangs on telling them apart. `EMFILE` clears when a pane
    /// closes — a remote connection costs three descriptors, so a window with
    /// enough of them reaches it — while a broken image never will. Before
    /// this the errno was stringified away at the throw, so the client had to
    /// treat both alike, and treating both as permanent killed a perfectly
    /// reachable machine for the life of the process.
    @Test("a spawn failure is classified by its errno, not by its wording")
    func spawnFailuresAreClassified() {
        func classify(_ domain: String, _ code: Int32) -> TransportError {
            CommandTransport.spawnError(
                NSError(domain: domain, code: Int(code)), command: "ssh")
        }

        for code in [EMFILE, ENFILE, EAGAIN, ENOMEM] {
            #expect(
                classify(NSPOSIXErrorDomain, code).isTransient,
                "errno \(code) is worth a retry")
        }
        for code in [ENOENT, EACCES, ENOEXEC, EISDIR] {
            #expect(
                !classify(NSPOSIXErrorDomain, code).isTransient,
                "errno \(code) will not fix itself")
        }
        // What Foundation actually raises for a missing or unreadable image.
        #expect(!classify(NSCocoaErrorDomain, 4).isTransient)
        #expect(!classify(NSCocoaErrorDomain, 257).isTransient)

        // Unknown means retry: one attempt every thirty seconds is cheaper
        // than giving up on a machine that was briefly out of something.
        #expect(classify(NSPOSIXErrorDomain, EINTR).isTransient)

        // And whichever it is, it reads like a sentence rather than a dump.
        //
        // The permanent case does not relay Foundation's wording at all: for
        // the file it is actually about -- present, not executable -- that
        // wording is "The file ... doesn't exist.", which sends somebody
        // looking for an `ssh` that is sitting where they left it.
        #expect(
            String(describing: classify(NSCocoaErrorDomain, 4))
                == "ssh is not an executable program")
        let transient = String(describing: classify(NSPOSIXErrorDomain, EMFILE))
        #expect(transient.hasPrefix("could not run ssh: "))
        #expect(!transient.contains("UserInfo="))
    }

    /// `close()` is called from the main actor, once per pane. Blocking there
    /// while a wedged child fails to die froze the window for seconds when
    /// closing a split tab — up to four seconds per connection, and a four-pane
    /// tab closes four of them.
    @Test("closing does not block the caller on a child that ignores SIGTERM")
    func closeDoesNotBlockTheCaller() async throws {
        // `trap` without `exec`: the shell keeps ignoring SIGTERM, so
        // `shutdown()` cannot end it and the reader never sees end-of-file.
        let transport = try CommandTransport(
            argv: ["/bin/sh", "-c", "trap '' TERM; sleep 2"])
        let connection = Connection(transport: transport)
        connection.start()

        // Let the reader actually reach its `read`. Without this it is still
        // at the loop's `closed` guard when `close` runs, exits immediately,
        // and the wait this test is about succeeds at once — which is how an
        // earlier version of it passed with the fix removed.
        try await Task.sleep(for: .milliseconds(200))

        let start = Date()
        connection.close()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.5, "close() blocked its caller for \(elapsed)s")
    }

    /// The message must survive the close that follows it. Closing used to
    /// free the stderr descriptor with bytes still undrained, so the one thing
    /// this mechanism exists to capture was thrown away with it.
    ///
    /// This is also where the *ordering* is defended, and more sharply than
    /// intended: make `close`'s `stderrHandle.close()` unconditional and the
    /// whole bundle aborts with SIGABRT inside
    /// `-[NSConcreteFileHandle readDataUpToLength:error:]`. Closing a handle a
    /// thread is reading raises an ObjC exception on *that* thread, which no
    /// `try?` on this side can catch. `close` runs a fraction of a millisecond
    /// after the spawn, so the drain is reliably still inside its read.
    @Test("a failure message survives the close that follows it")
    func diagnosticsSurviveClose() throws {
        let transport = try CommandTransport(
            argv: ["/bin/sh", "-c", "echo 'could not resolve hostname' >&2; exit 1"])
        // No `shutdown()` first: this child exits on its own, and terminating
        // it would race SIGTERM against its own `echo`. What is under test is
        // that `close` does not free the descriptor until the drain has read
        // to end-of-file.
        transport.close()

        // Only the process reaping is raced; the bytes are already in hand.
        for _ in 0..<200 where transport.isRunning { usleep(5000) }
        #expect(transport.failureDescription == "could not resolve hostname")
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

        let local = ServerHost.local(socketPath: "/tmp/s.sock")
        #expect(
            try JSONDecoder().decode(ServerHost.self, from: JSONEncoder().encode(local))
                == local)
    }

    /// Round-tripping our own encoder's output cannot see this: it always
    /// writes the key. The synthesized `Codable` did *not* honour the case's
    /// `= "illogicald"` default and threw `keyNotFound` — and since the whole
    /// array decodes under one `try?`, a single such entry silently forgot
    /// every remembered host rather than one field.
    @Test("a stored host missing the optional key still decodes")
    func hostCodingToleratesAMissingDefault() throws {
        let json = Data(#"{"ssh":{"destination":"me@build-box"}}"#.utf8)
        let decoded = try JSONDecoder().decode(ServerHost.self, from: json)
        #expect(decoded == .ssh(destination: "me@build-box", remoteBinary: "illogicald"))
    }
}
