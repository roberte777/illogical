//  LocalDaemonTests.swift
//  Starting the local server, without starting one.
//
//  Every test here stands a shell script in for `illogicald` and passes it as
//  `Options.executable`, so nothing in this suite touches the process
//  environment and nothing can reach a developer's real socket. The one test
//  that does look at `ILLOGICAL_DAEMON` asks the resolver about a dictionary it
//  was handed, the way `SSHCommand.controlPath` is tested — a pure function of
//  an environment rather than of *the* environment.
//
//  The argv is asserted argument by argument for the same reason the ssh
//  command is: `--socket` going missing would still start a daemon, just not
//  the one the app is about to connect to.

import Darwin
import Foundation
import Testing

@testable import IllogicalProtocol

@Suite("The local daemon", .serialized)
struct LocalDaemonTests {
    /// A directory that goes away with the test.
    private static func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "illogical-localdaemon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A stand-in for `illogicald`, so the assertions are about this file and
    /// not about a daemon.
    private static func script(
        _ directory: URL, _ body: String, named name: String = "illogicald"
    ) throws -> URL {
        let url = directory.appending(path: name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - What gets run

    @Test("runs --ensure against the socket the app chose")
    func argvShape() {
        let argv = LocalDaemon.argv(
            executable: URL(
                fileURLWithPath: "/Applications/Illogical.app/Contents/MacOS/illogicald"),
            socketPath: "/tmp/illogical/server.sock")
        #expect(
            argv == [
                "/Applications/Illogical.app/Contents/MacOS/illogicald",
                "--ensure",
                "--socket", "/tmp/illogical/server.sock",
            ])
    }

    @Test("never asks for a bridge")
    func notStdio() {
        // A local `--stdio` would work and is the thing this design rejects: a
        // process and a copy per connection, five of them for a window with
        // four splits.
        let argv = LocalDaemon.argv(
            executable: URL(fileURLWithPath: "/bin/true"), socketPath: "/tmp/s.sock")
        #expect(!argv.contains("--stdio"))
    }

    @Test("the daemon can be pointed elsewhere, without touching PATH")
    func executableOverride() {
        let resolved = LocalDaemon.executable(
            environment: ["ILLOGICAL_DAEMON": "/opt/illogicald"])
        #expect(resolved?.path == "/opt/illogicald")
    }

    @Test("an empty override is not an override")
    func emptyOverride() {
        // `ILLOGICAL_DAEMON=` in a bench script's environment must not resolve
        // to the current directory.
        #expect(LocalDaemon.executable(environment: ["ILLOGICAL_DAEMON": ""]) == nil)
    }

    @Test("a process with no bundled daemon resolves none, so no test can spawn one")
    func noDaemonInATestProcess() {
        // The structural half of "the tests never start a daemon at the
        // developer's real socket path": an xctest host has no auxiliary
        // executable, so a `SessionStore` that reached `connect()` with the
        // real launcher would get `.notBundled` rather than a daemon.
        #expect(LocalDaemon.executable(environment: [:]) == nil)
    }

    // MARK: - Running it

    @Test("a daemon that starts reports that it started")
    func started() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = try Self.script(directory, "echo \"illogicald started, listening on $3\"")

        let outcome = try await LocalDaemon.ensure(
            LocalDaemon.Options(socketPath: "\(directory.path)/server.sock", executable: stub))
        #expect(outcome == .started)
    }

    @Test("a daemon that was already there is not started again")
    func alreadyRunning() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = try Self.script(directory, "echo \"illogicald is already running on $3\"")

        // Both outcomes are a success and the caller does not branch on this,
        // but the difference is the whole of D3.1: whatever already owns the
        // socket owns the terminals, and the app never replaces it.
        let outcome = try await LocalDaemon.ensure(
            LocalDaemon.Options(socketPath: "\(directory.path)/server.sock", executable: stub))
        #expect(outcome == .alreadyRunning)
    }

    @Test("a daemon that refuses is quoted by its last line and nothing else")
    func failureIsQuoted() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The real stderr of a failed `--ensure`: a progress line from
        // `spawnDaemon`, then the verdict. The verdict is the whole sentence —
        // it names the socket, the reason and the daemon.log itself — and
        // everything above it is noise to whoever is reading "No server".
        let stub = try Self.script(
            directory,
            """
            echo "info(stdio): no daemon; starting one" >&2
            echo "illogicald --ensure: boom" >&2
            exit 1
            """)
        let socket = "\(directory.path)/server.sock"

        do {
            _ = try await LocalDaemon.ensure(
                LocalDaemon.Options(socketPath: socket, executable: stub))
            Issue.record("a daemon that exits 1 must not report success")
        } catch {
            // Equality, not `contains`: what the app shows is exactly what the
            // daemon said, with nothing of ours in front of it. Before this it
            // was the progress line first and a Zig return trace after
            // (REVIEW F4).
            let text = "\(error)"
            #expect(text == "illogicald --ensure: boom")
            #expect(!text.contains("info("))
            #expect(!text.contains("NSCocoaErrorDomain"))
        }
    }

    @Test("a daemon that exits without saying anything still names its status")
    func silentFailure() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = try Self.script(directory, "exit 3")

        let socket = "\(directory.path)/server.sock"

        do {
            _ = try await LocalDaemon.ensure(
                LocalDaemon.Options(socketPath: socket, executable: stub))
            Issue.record("a daemon that exits 3 must not report success")
        } catch {
            let text = "\(error)"
            #expect(text.contains("exited 3"))
            // This is the sentence that has to name the socket, because it is
            // the app's own: a daemon that said nothing left nothing to quote,
            // and a machine with two of them cannot otherwise be told apart.
            #expect(text.contains(socket))
        }
    }

    @Test("a child that never returns is killed, not left behind")
    func timeoutKillsTheChild() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Records its own pid, then hangs. `trap` on nothing, so SIGTERM is
        // enough — the escalation to SIGKILL is for a child that ignores it.
        let pidFile = "\(directory.path)/pid"
        let stub = try Self.script(directory, "echo $$ > \(pidFile); sleep 60")

        let start = Date()
        do {
            _ = try await LocalDaemon.ensure(
                LocalDaemon.Options(
                    socketPath: "\(directory.path)/server.sock",
                    executable: stub,
                    timeout: .milliseconds(300)))
            Issue.record("a child that hangs must not report success")
        } catch {
            #expect("\(error)".contains("did not start a server"))
        }
        // The bound is the timeout, not the child's own sixty seconds.
        #expect(Date().timeIntervalSince(start) < 10)

        // And the child is actually gone: reaped, so not even a zombie. The
        // app runs this again on every outage, and children that accumulate one
        // per failed reconnect is the failure a spawn helper must not have.
        let recorded = try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(recorded))
        #expect(kill(pid, 0) != 0)
    }

    @Test("a daemon that is not there is a spawn failure, not a hang")
    func missingExecutable() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await LocalDaemon.ensure(
                LocalDaemon.Options(
                    socketPath: "\(directory.path)/server.sock",
                    executable: directory.appending(path: "no-such-daemon")))
            Issue.record("a missing daemon must not report success")
        } catch {
            // `CommandTransport`'s mapping, reused: permanent, and it says the
            // file is not there rather than Foundation's sentence about a file
            // that does exist.
            guard case .spawn(let transport) = error as? LocalDaemonError else {
                Issue.record("expected a spawn failure, got \(error)")
                return
            }
            #expect(!transport.isTransient)
            #expect("\(error)".contains("is not there"))
            #expect((error as? LocalDaemonError)?.isTransient == false)
        }
    }

    @Test("a file that is not executable is a permanent failure")
    func notExecutable() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = directory.appending(path: "illogicald")
        try "not a program".write(to: plain, atomically: true, encoding: .utf8)

        do {
            _ = try await LocalDaemon.ensure(
                LocalDaemon.Options(
                    socketPath: "\(directory.path)/server.sock", executable: plain))
            Issue.record("a file that cannot be run must not report success")
        } catch {
            #expect("\(error)".contains("is not executable"))
            // Retrying this every thirty seconds for the life of the process
            // tells nobody anything.
            #expect((error as? LocalDaemonError)?.isTransient == false)
        }
    }

    @Test("a bundle with no daemon in it says so rather than searching PATH")
    func notBundled() async throws {
        // `executable` nil and no `ILLOGICAL_DAEMON` in a test process, which
        // is `notBundled` by construction.
        do {
            _ = try await LocalDaemon.ensure(LocalDaemon.Options(socketPath: "/tmp/never.sock"))
            Issue.record("a test process has no bundled daemon")
        } catch {
            #expect(error as? LocalDaemonError == .notBundled)
            #expect((error as? LocalDaemonError)?.isTransient == false)
        }
    }

    // MARK: - Version

    @Test("the version is the second field, so the program's name is not part of it")
    func versionIsParsed() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = try Self.script(directory, "echo 'illogicald 0.0.0-dev+gabc123456789'")

        #expect(await LocalDaemon.version(executable: stub) == "0.0.0-dev+gabc123456789")
    }

    @Test("a binary that answers nothing useful reports no version, rather than a wrong one")
    func versionUnavailable() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A version we could not determine is a comparison the app does not
        // make. Reporting a garbage string instead would put a skew warning in
        // front of somebody whose daemon is fine.
        let silent = try Self.script(directory, "exit 0", named: "silent")
        #expect(await LocalDaemon.version(executable: silent) == nil)

        let refuses = try Self.script(
            directory, "echo 'illogicald 1.2.3'; exit 2", named: "refuses")
        #expect(await LocalDaemon.version(executable: refuses) == nil)

        #expect(
            await LocalDaemon.version(executable: directory.appending(path: "absent")) == nil)
    }
}
