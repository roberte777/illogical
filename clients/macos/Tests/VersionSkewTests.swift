//  VersionSkewTests.swift
//  Noticing that the server is not the one the app shipped.
//
//  Two different things, both reached through a `welcome` or an `err` on the
//  control session, and the difference between them is the whole point:
//
//      welcome.server differs   →  a marker and a tooltip. Nothing blocked.
//      err(version_mismatch)    →  .failed, and the retries stop.
//
//  The first is a build we cannot vouch for; the second is a daemon that will
//  refuse every `hello` we ever send it. What that used to do was not a
//  reconnect loop -- it was worse and quieter: the app logged the refusal, took
//  the `session_list` the daemon had queued behind it, and attached 55 ms later
//  to a daemon whose protocol it does not speak (REVIEW F1). So the assertion
//  that matters here is not "it says something", it is "it says it and then
//  ignores everything that follows".
//
//  Driven with `handleForTesting`, which is the production `apply`, so a frame
//  here takes the same path a frame off the wire does.

import IllogicalProtocol
import XCTest

@MainActor
final class VersionSkewTests: XCTestCase {

    /// Somewhere in memory for the store to read its remembered host and write
    /// its front session, rather than the developer's own preferences.
    private final class InMemoryDefaults: HostDefaults {
        private var values: [String: Data] = [:]
        func data(forKey defaultName: String) -> Data? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) {
            values[defaultName] = value as? Data
        }
    }

    /// A launcher that starts nothing and reports a fixed bundled version.
    private final class StubLauncher: DaemonLauncher, @unchecked Sendable {
        let version: String?
        /// The delay before answering, so a second `welcome` can arrive while
        /// the first lookup is still suspended. Zero by default.
        let latency: Duration
        private let lock = NSLock()
        private var _versionCalls = 0
        /// How many times `bundledVersion()` was entered. Running
        /// `illogicald --version` is a process, and the point of counting is
        /// that a reconnect must not start a second one.
        var versionCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return _versionCalls
        }

        init(version: String?, latency: Duration = .zero) {
            self.version = version
            self.latency = latency
        }

        func ensure(socketPath: String) async throws -> LocalDaemon.Outcome {
            XCTFail("no test here should reach the launcher's spawn")
            return .started
        }

        func bundledVersion() async -> String? {
            // The count is taken in a synchronous helper for the same reason
            // `RecordingLauncher`'s work is: `NSLock.lock()` is unavailable
            // from an async context, and this method is async because the real
            // launcher waits for a child.
            noteCall()
            if latency != .zero { try? await Task.sleep(for: latency) }
            return version
        }

        private func noteCall() {
            lock.lock()
            defer { lock.unlock() }
            _versionCalls += 1
        }
    }

    private func host(shipping version: String?) throws -> HostConnection {
        try host(StubLauncher(version: version))
    }

    private func host(_ launcher: StubLauncher) throws -> HostConnection {
        let path = "/tmp/illogical-skew-\(getpid())-\(UInt32.random(in: 0..<1_000_000)).sock"
        let store = SessionStore(
            hosts: [.local(socketPath: path)], defaults: InMemoryDefaults(),
            launcher: launcher)
        return try XCTUnwrap(store.host(.local(socketPath: path)), "no host")
    }

    private func welcome(_ server: String) -> Frame {
        Frame(
            type: .welcome, terminal: Protocol.controlSession,
            payload: Data(#"{"version":1,"server":"\#(server)"}"#.utf8))
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(description)")
    }

    // MARK: - welcome.server

    func testTheSameBuildIsNotReported() async throws {
        let host = try host(shipping: "0.0.0-dev+gabc123456789")
        defer { host.disconnect() }

        host.handleForTesting(welcome("0.0.0-dev+gabc123456789"))
        try await waitFor("the version to be read") { host.serverVersion != nil }
        // The lookup is a Task, so give a wrong answer time to arrive rather
        // than passing because nothing has happened yet.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(host.versionSkew, "a matching daemon was reported as skewed")
    }

    func testADifferentBuildIsReportedWithBothStrings() async throws {
        let host = try host(shipping: "0.0.0-dev+gabc123456789")
        defer { host.disconnect() }

        host.handleForTesting(welcome("0.0.0-dev+gdef987654321"))
        try await waitFor("the skew to be noticed") { host.versionSkew != nil }
        // Both, because either alone is useless: "your server is old" without
        // saying which two builds are involved tells nobody what to do.
        XCTAssertEqual(host.versionSkew?.server, "0.0.0-dev+gdef987654321")
        XCTAssertEqual(host.versionSkew?.shipped, "0.0.0-dev+gabc123456789")
    }

    /// The pin is the half that matters. Two builds of the same release
    /// against different `vendor/ghostty` revisions disagree about the
    /// snapshot format, and format v1 promises nothing across pins — so they
    /// must compare unequal even though the version in front is identical.
    func testTwoBuildsThatDifferOnlyInThePinAreDifferent() async throws {
        let host = try host(shipping: "1.2.3+gaaaaaaaaaaaa")
        defer { host.disconnect() }

        host.handleForTesting(welcome("1.2.3+gbbbbbbbbbbbb"))
        try await waitFor("the skew to be noticed") { host.versionSkew != nil }
    }

    /// A remote daemon is *expected* to be a different build: it was installed
    /// from a tarball, on its own schedule, possibly by somebody else. Marking
    /// every one of them would make the marker mean nothing.
    func testARemoteHostIsNeverCompared() async throws {
        let store = SessionStore(
            hosts: [.ssh(destination: "build-box")], defaults: InMemoryDefaults(),
            launcher: StubLauncher(version: "0.0.0-dev+gabc123456789"))
        let host = try XCTUnwrap(store.host(.ssh(destination: "build-box")), "no host")
        defer { host.disconnect() }

        host.handleForTesting(welcome("9.9.9+gzzzzzzzzzzzz"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(host.versionSkew, "a remote daemon was marked for not being ours")
    }

    /// A version we could not read is a comparison we do not make. Reporting
    /// skew against nothing would put an amber triangle in front of everybody
    /// running a build with no daemon staged into it.
    func testNoBundledVersionMeansNoComparison() async throws {
        let host = try host(shipping: nil)
        defer { host.disconnect() }

        host.handleForTesting(welcome("0.0.0-dev+gdef987654321"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(host.versionSkew)
        // ...but the server's own version is still known, because that half
        // needed nothing from the bundle.
        XCTAssertEqual(host.serverVersion, "0.0.0-dev+gdef987654321")
    }

    // MARK: - err(version_mismatch)

    /// The daemon refused our `hello` over the *protocol* version, and then —
    /// as a real one did, because a client pipelines `hello` and `list` — sent
    /// the reply to the `list` anyway. The frames below are the sequence
    /// observed in review against a daemon built with `protocol.version = 2`.
    func testAProtocolMismatchIsTerminalRatherThanAReconnectLoop() async throws {
        let launcher = StubLauncher(version: "0.0.0-dev+gabc123456789")
        let host = try host(launcher)
        defer { host.disconnect() }

        host.handleForTesting(
            Frame(
                type: .error, terminal: Protocol.controlSession,
                payload: Data(#"{"code":1,"message":"unsupported protocol version"}"#.utf8)))

        guard case .failed(let message) = host.status else {
            return XCTFail("a hopeless protocol mismatch was left retrying: \(host.status)")
        }
        XCTAssertTrue(
            message.contains("protocol"),
            "the sentence does not say what is wrong: \(message)")
        let attemptWhenRefused = host.backoffAttemptForTesting

        // The frame that used to undo all of it, one line later. `apply` reads
        // a `session_list` as "connected" — that is the whole of how the app
        // came to attach to a daemon it had just refused.
        host.handleForTesting(
            Frame(
                type: .sessionList, terminal: Protocol.controlSession,
                payload: Data(#"{"sessions":[],"terminals":[]}"#.utf8)))
        guard case .failed = host.status else {
            return XCTFail("a session_list undid the refusal: \(host.status)")
        }
        XCTAssertFalse(host.status.isConnected)
        XCTAssertEqual(
            host.backoffAttemptForTesting, attemptWhenRefused,
            "the refused connection went back into the backoff")

        // And a `welcome` from the same still-talking daemon is not a reason to
        // go and read a version off it, either.
        host.handleForTesting(
            Frame(
                type: .welcome, terminal: Protocol.controlSession,
                payload: Data(#"{"version":1,"server":"9.9.9+gzzzzzzzzzzzz"}"#.utf8)))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(host.serverVersion, "a refused daemon's version was recorded")
        XCTAssertEqual(launcher.versionCalls, 0, "a refused daemon started a version lookup")

        // And it stays failed. `.failed` has to mean the retries stopped, or
        // the amber spinner comes back a quarter of a second later and the
        // sentence a person just read is gone.
        try await Task.sleep(for: .milliseconds(500))
        guard case .failed = host.status else {
            return XCTFail("a terminal failure slid back into the backoff: \(host.status)")
        }
    }

    /// `illogicald --version` is a process. A reconnect while the first lookup
    /// is still suspended must not start a second one (REVIEW F13).
    func testTheShippedVersionIsLookedUpOnceEvenIfTwoWelcomesRace() async throws {
        let launcher = StubLauncher(
            version: "0.0.0-dev+gabc123456789", latency: .milliseconds(100))
        let host = try host(launcher)
        defer { host.disconnect() }

        host.handleForTesting(welcome("0.0.0-dev+gdef987654321"))
        try await Task.sleep(for: .milliseconds(10))
        host.handleForTesting(welcome("0.0.0-dev+gdef987654321"))

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(launcher.versionCalls, 1, "the bundled version was looked up twice")
    }

    /// Every other control error is still just a failed request. Voiding the
    /// creates is all it means, and turning it into a dead host would kill a
    /// machine over one bad `create`.
    func testAnOrdinaryControlErrorIsNotTerminal() async throws {
        let host = try host(shipping: "0.0.0-dev+gabc123456789")
        defer { host.disconnect() }

        host.handleForTesting(
            Frame(
                type: .error, terminal: Protocol.controlSession,
                payload: Data(#"{"code":2,"message":"no such session"}"#.utf8)))

        if case .failed = host.status {
            XCTFail("an ordinary control error killed the host")
        }
    }

    /// The lists survive it. A daemon we cannot speak to still has the
    /// terminals it told us about, and clearing them would take every tab on
    /// the machine with them through the reconcile.
    func testAProtocolMismatchKeepsTheTerminalsItAlreadyKnowsAbout() async throws {
        let host = try host(shipping: "0.0.0-dev+gabc123456789")
        defer { host.disconnect() }

        host.handleForTesting(
            Frame(
                type: .sessionList, terminal: Protocol.controlSession,
                payload: Data(
                    #"""
                    {"sessions":[{"id":1,"name":"one","terminals":[7]}],
                     "terminals":[{"id":7,"session":1,"name":"a","command":"/bin/zsh",
                     "cwd":"/","cols":80,"rows":24,"residency":"live","attached":0,
                     "pty_read_idle_ns":0}]}
                    """#.utf8)))
        XCTAssertEqual(host.terminals.count, 1)

        host.handleForTesting(
            Frame(
                type: .error, terminal: Protocol.controlSession,
                payload: Data(#"{"code":1,"message":"unsupported protocol version"}"#.utf8)))
        XCTAssertEqual(host.terminals.count, 1, "a protocol mismatch closed every tab")
    }
}
