//  LocalDaemon.swift
//  Starting the local server, when there is none.
//
//  The app connects to the unix socket exactly as it always has. Only when that
//  connect is refused does anything here run — and what it runs is one short
//  command:
//
//      <Illogical.app>/Contents/MacOS/illogicald --ensure --socket <path>
//
//  which makes sure a daemon is listening and exits. Then the app connects
//  again, over the socket, and nothing on the fast path knows any of this
//  happened.
//
//  Three things about that shape are deliberate.
//
//  **It is not `--stdio`.** The bridge would give us spawn-if-missing for free,
//  and it would put a process and a byte copy on every *local* connection — a
//  window with four splits is five bridges. M5 measured the bridge at +10% on a
//  whole snapshot. The local path must stay one `connect()`.
//
//  **It is not a reimplementation.** `--ensure` is `src/daemon/stdio.zig`'s
//  dial-or-start with the bridge left off: double fork, `setsid`, `/dev/null`
//  stdio, an append-only `daemon.log`, `closeFrom(3)`. Doing it here instead
//  would mean `posix_spawn` with the right flags — `fork()` in a multithreaded
//  Cocoa process is not safe — a second implementation of a thing that is
//  already tested on both platforms in CI, and two spawn paths free to drift
//  apart. The SSH path *is* this path with a pipe in front of it.
//
//  **It is not a child of the app.** `--ensure` is; the daemon is not. By the
//  time `--ensure` exits, the daemon is two forks away in a session of its own,
//  reparented to launchd, holding none of our descriptors. ⌘Q, a crash, Xcode's
//  Stop button and `pkill Illogical` all leave it running with its terminals
//  intact, which is the entire point of a session server (G1). A plain
//  `Process` running `illogicald --socket …` would have failed every one of
//  those.
//
//  See docs/PROTOCOL.md, "Transport", and `src/daemon/stdio.zig`.

import Darwin
import Foundation

/// Runs `illogicald --ensure`, and nothing else.
///
/// A namespace rather than an object: it holds no state, owns nothing after it
/// returns, and the daemon it leaves behind belongs to no one.
public enum LocalDaemon {
    /// Which of the two things happened. Both mean the same thing to a caller
    /// — there is a daemon now — so nothing branches on this; it is what a log
    /// line says and what a test can assert on.
    public enum Outcome: Sendable, Equatable {
        /// Something was already listening, and we started nothing. The
        /// important case: whatever owns the socket owns the terminals behind
        /// it, and the app never replaces it.
        case alreadyRunning
        /// There was nothing, so a daemon was started and bound its socket.
        case started
    }

    public struct Options: Sendable {
        /// The socket that must have a daemon on it when this returns.
        public var socketPath: String

        /// The daemon to run. Nil asks `executable()` for the bundled one.
        public var executable: URL?

        /// How long the `--ensure` child gets before it is killed.
        ///
        /// Deliberately longer than the daemon's own `startup_timeout_ns` (ten
        /// seconds, `stdio.Options`). A daemon that is merely slow to bind on a
        /// cold disk should report its own timeout — with the `daemon.log` path
        /// in it — rather than be killed mid-start and reported here as the
        /// app's failure. This bound is for a child that has stopped answering
        /// altogether.
        public var timeout: Duration

        public init(socketPath: String, executable: URL? = nil, timeout: Duration = .seconds(15)) {
            self.socketPath = socketPath
            self.executable = executable
            self.timeout = timeout
        }
    }

    /// The daemon this app would start.
    ///
    /// `ILLOGICAL_DAEMON` first — the local analogue of `ILLOGICAL_SSH`, and
    /// the seam every test and every bench script uses so that nothing in a
    /// developer's tree ever starts a daemon at their real socket path.
    ///
    /// Then the binary inside the bundle, by absolute path, and never
    /// `illogicald` from `PATH`. Two reasons, and the second is the real one: a
    /// GUI app's `PATH` has nothing user-installed in it anyway, and the
    /// bundled binary was built from the same `vendor/ghostty` commit as the
    /// app's own XCFramework by the same `just` invocation — so it is the one
    /// daemon guaranteed to agree with this app's snapshot decoder.
    ///
    /// Nil in a test process and in any other host with no auxiliary
    /// executable, which is what keeps a test that reaches `connect()` from
    /// starting a real daemon.
    ///
    /// It resolves through the bundle *every time* rather than caching a path.
    /// The daemon runs from inside the app bundle, so a Sparkle update or a
    /// drag to the Trash moves or removes the file underneath us; a running
    /// daemon is unaffected — it holds the inode — but the next spawn must come
    /// from wherever the app is now.
    public static func executable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment["ILLOGICAL_DAEMON"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forAuxiliaryExecutable: "illogicald")
    }

    /// What gets run. Asserted argument by argument in the tests, the way
    /// `SSHCommand.argv` is, because none of it fails loudly if it goes
    /// missing.
    public static func argv(executable: URL, socketPath: String) -> [String] {
        [
            executable.path,
            // Not `--stdio`. See the file header: a bridge per local
            // connection is what this design exists to avoid.
            "--ensure",
            // Always explicit, never left to the daemon's own default. The
            // daemon would resolve the path from *its* environment, and its
            // environment is launchd's rather than a shell's — so an
            // `ILLOGICAL_SOCK` or `XDG_STATE_HOME` the app is honouring would
            // be invisible to the daemon the app started, and the two would
            // end up on different sockets.
            "--socket", socketPath,
        ]
    }

    /// Make sure a daemon is listening on `options.socketPath`.
    ///
    /// `async`, and that is a requirement rather than a style: the caller is
    /// `HostConnection`, which is `@MainActor`, and this waits for a child that
    /// may take ten seconds on a cold disk. A `waitUntilExit` on that actor is
    /// a frozen window, and the launch budget (G7) says nothing on screen may
    /// wait for a server.
    ///
    /// Everything it throws is a `LocalDaemonError`, and it would say so in the
    /// signature if it could: the devshell's swift-format is a swift-syntax 508
    /// build and cannot parse `throws(E)`, so `just fmt-check` -- which is a CI
    /// gate -- rejects the file outright. Callers match on the concrete type.
    public static func ensure(_ options: Options) async throws -> Outcome {
        guard let executable = options.executable ?? executable() else {
            throw LocalDaemonError.notBundled
        }

        let arguments = Array(
            argv(executable: executable, socketPath: options.socketPath).dropFirst())
        switch await run(executable: executable, arguments: arguments, timeout: options.timeout) {
        case .spawnFailed(let error):
            throw LocalDaemonError.spawn(error)
        case .timedOut:
            throw LocalDaemonError.timedOut(socket: options.socketPath, after: options.timeout)
        case .finished(let child):
            guard child.status == 0 else {
                throw LocalDaemonError.failed(
                    socket: options.socketPath, status: child.status, stderr: child.stderr)
            }
            // The daemon's one line of stdout, read only to tell the two
            // successes apart. Tolerant on purpose: if a future daemon words it
            // differently this reports `.started` for a daemon that was already
            // there, which costs a log line and nothing else. Nothing branches
            // on the answer.
            return child.stdout.contains("already running") ? .alreadyRunning : .started
        }
    }

    /// What `<executable> --version` says its version is, or nil.
    ///
    /// Optional rather than throwing because there is exactly one caller and
    /// one use: comparing the daemon the app shipped against the daemon it is
    /// talking to, so that a mismatch can be *mentioned*. A version we could
    /// not determine is a comparison we do not make — never a reason to fail a
    /// connection, and never a sentence to put in front of a person.
    public static func version(executable: URL) async -> String? {
        // Short. Unlike `--ensure` this waits for nothing but a `write` and an
        // `exit`; a binary that has not answered in five seconds is not going
        // to.
        let result = await run(
            executable: executable, arguments: ["--version"], timeout: .seconds(5))
        guard case .finished(let child) = result, child.status == 0 else { return nil }
        // `illogicald 0.0.0-dev+g492300cad104`. The second field, because the
        // first is the program's own name — which differs between `illogicald`
        // and `illogical`, and would otherwise make two builds of the same
        // commit compare unequal.
        let fields = child.stdout.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        return String(fields[1])
    }

    // MARK: - Running the child

    /// A child that ran to completion, and everything it said.
    private struct Finished {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private enum RunResult {
        case finished(Finished)
        case spawnFailed(TransportError)
        case timedOut
    }

    private static func run(
        executable: URL, arguments: [String], timeout: Duration
    ) async -> RunResult {
        await withCheckedContinuation { continuation in
            // A thread of its own rather than the cooperative pool. This blocks
            // for as long as the daemon takes to bind its socket, and a Task
            // that parks a pool thread for ten seconds starves every other Task
            // in the app — including the ones drawing the window that is
            // waiting for it.
            //
            // The `Process` is created inside the closure, so nothing
            // non-Sendable crosses into the thread.
            let thread = Thread {
                continuation.resume(
                    returning: runSynchronously(
                        executable: executable, arguments: arguments, timeout: timeout))
            }
            thread.name = "illogical.local-daemon"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    private static func runSynchronously(
        executable: URL, arguments: [String], timeout: Duration
    ) -> RunResult {
        let out = Pipe()
        let err = Pipe()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        // No stdin at all. `--ensure` reads none, and a descriptor of the app's
        // in the hands of a process that is about to fork a daemon is exactly
        // the kind of thing `closeFrom(3)` exists to sweep up — better not to
        // hand it over in the first place.
        process.standardInput = FileHandle.nullDevice

        // Signalled by Foundation's own reaper, so the wait below is an event
        // rather than a poll.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            // `CommandTransport`'s mapping, deliberately reused rather than
            // rewritten: it is the one place that turns Foundation's
            // "NSCocoaErrorDomain Code=4 — The file doesn't exist." into
            // something true about a file that is sitting right there, and it
            // is where the retryable/permanent split lives. A missing bundled
            // daemon and a missing `ssh` are the same failure.
            return .spawnFailed(
                CommandTransport.spawnError(
                    error, command: executable.path, path: executable.path))
        }

        // Drained on threads of their own rather than read after the wait. A
        // pipe holds 64 KiB and a child that fills one blocks inside `write`,
        // which from out here is indistinguishable from a daemon that is slow
        // to bind — and the wait below would then kill a child that was working
        // perfectly. Same reasoning, and the same shape, as `CommandTransport`.
        let stdoutText = drain(out.fileHandleForReading)
        let stderrText = drain(err.fileHandleForReading)

        var timedOut = false
        if finished.wait(timeout: .now() + duration(timeout)) == .timedOut {
            timedOut = true
            // Ended rather than abandoned. The app runs `ensure` again on the
            // next outage, and a pile of stuck children accumulating one per
            // failed reconnect is the one failure mode a spawn helper must not
            // have. Note this kills the `--ensure` child only: a daemon it
            // already forked is in another session and is not ours to end.
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        // Reaped, not merely signalled, so the pid is gone rather than a
        // zombie.
        process.waitUntilExit()

        let status = process.terminationStatus
        // After the wait: these return when the child's ends of the pipes
        // close, which is when it exits.
        let stdout = stdoutText()
        let stderr = stderrText()

        if timedOut { return .timedOut }
        return .finished(Finished(status: status, stdout: stdout, stderr: stderr))
    }

    /// Read `handle` to end-of-file on a thread, and return the function that
    /// waits for it.
    private static func drain(_ handle: FileHandle) -> () -> String {
        let done = DispatchSemaphore(value: 0)
        let box = TextBox()
        let thread = Thread {
            box.set(handle.readDataToEndOfFile())
            done.signal()
        }
        thread.name = "illogical.local-daemon.io"
        thread.stackSize = 128 * 1024
        thread.start()
        return {
            done.wait()
            return box.text
        }
    }

    private final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func set(_ new: Data) {
            lock.lock()
            defer { lock.unlock() }
            data = new
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func duration(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// Why no daemon could be started.
///
/// Every case renders a sentence for a person, because every one of them ends
/// up in front of one: in the session dropdown next to the local host, and —
/// when local is the only host — as the whole window. `Error`'s own rendering
/// of these is `NSCocoaErrorDomain` noise.
public enum LocalDaemonError: Error, Equatable, CustomStringConvertible {
    /// There is no `illogicald` in this bundle and `ILLOGICAL_DAEMON` names
    /// none. True of every test process, and of the app only if `just
    /// stage-daemon` did not run.
    case notBundled
    /// The child could not be started at all — the errno mapping is
    /// `CommandTransport`'s, so this says which file and what is wrong with it.
    case spawn(TransportError)
    /// It ran, and refused. `stderr` is its own explanation, which for the real
    /// daemon already names the `daemon.log` that has the rest.
    ///
    /// The whole of stderr is kept here even though `description` quotes only
    /// its last line: the payload is what a Trace entry and a bug report want,
    /// and throwing the rest away at the point of capture would make it
    /// unrecoverable.
    case failed(socket: String, status: Int32, stderr: String)
    /// It neither started a daemon nor exited. Distinct from `failed` because
    /// there is nothing to quote: the child said nothing and was killed.
    case timedOut(socket: String, after: Duration)

    public var description: String {
        switch self {
        case .notBundled:
            "this build of the app has no illogicald in it"
        case .spawn(let error):
            "illogicald could not be started: \(error)"
        case .failed(let socket, let status, let stderr):
            // The daemon's *last* line, verbatim, with nothing in front of it.
            //
            // `illogicald --ensure` writes one self-contained sentence when it
            // gives up — it names the socket, the reason and the daemon.log —
            // and everything before it on that stream is progress ("info(stdio):
            // no daemon at …; starting one"). Quoting the whole of stderr put
            // the progress line first and, in a Debug build, a three-frame Zig
            // return trace with absolute source paths after it, and that is what
            // the app showed a person under "No server" (REVIEW F4). Prefixing
            // the last line would only say "illogicald" twice.
            //
            // The fallback is the app's own sentence, and it is the one that has
            // to name the socket: a daemon that failed without saying anything
            // has left nothing to quote.
            Self.lastLine(of: stderr)
                ?? "illogicald could not start a server on \(socket): it exited \(status)"
        case .timedOut(let socket, let after):
            "illogicald did not start a server on \(socket) within \(after)"
        }
    }

    /// The last line of `text` that has anything on it, or nil if none does.
    private static func lastLine(of text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Whether waiting and trying again could plausibly help.
    ///
    /// The same split, and for the same reason, as `TransportError.isTransient`
    /// — the client has to choose between an amber "reconnecting…" forever and
    /// stopping with a sentence. A bundle with no daemon in it will not grow
    /// one; a spawn that failed on `EMFILE` clears the moment a pane closes.
    public var isTransient: Bool {
        switch self {
        case .notBundled: false
        case .spawn(let error): error.isTransient
        // Both retryable: a daemon that failed to start on a full disk or a
        // busy machine can start on the next try, and the alternative is a
        // window that says "no server" until it is relaunched.
        case .failed, .timedOut: true
        }
    }
}
