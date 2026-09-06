//  ReconnectTests.swift
//  Losing a connection, and getting it back.
//
//  Driven against a real unix socket rather than a mock, because the thing
//  under test is what happens when a socket the reader thread is blocked on
//  goes away — which is not something a mock can be wrong about in the same
//  way.
//
//  The claim these are here to defend is that reconnecting needed almost no
//  new machinery. A connection that goes away is a client that has missed
//  output, the protocol already recovers from that by replaying the attach
//  handshake, and the server keeps the terminal running throughout. So what is
//  asserted below is mostly *when* rather than *what*.

import Darwin
import IllogicalProtocol
import XCTest

@MainActor
final class ReconnectTests: XCTestCase {

    // MARK: - The schedule

    func testBackoffGrowsAndThenStops() {
        XCTAssertEqual(Backoff.delay(forAttempt: 0), Backoff.initial)
        XCTAssertEqual(Backoff.delay(forAttempt: 1), 0.5, accuracy: 0.001)
        XCTAssertEqual(Backoff.delay(forAttempt: 2), 1.0, accuracy: 0.001)
        XCTAssertEqual(Backoff.delay(forAttempt: 3), 2.0, accuracy: 0.001)

        // A host that is genuinely gone must cost one connection attempt every
        // half minute, not a spin, and must never stop trying: a laptop closed
        // overnight should find its terminals in the morning.
        XCTAssertEqual(Backoff.delay(forAttempt: 20), Backoff.ceiling)
        XCTAssertEqual(Backoff.delay(forAttempt: 1000), Backoff.ceiling)
    }

    func testBackoffAdvancesAndResets() {
        var backoff = Backoff()
        XCTAssertEqual(backoff.next(), Backoff.initial)
        XCTAssertEqual(backoff.attempt, 1)
        _ = backoff.next()
        _ = backoff.next()
        XCTAssertEqual(backoff.attempt, 3)

        backoff.reset()
        XCTAssertEqual(backoff.attempt, 0)
        XCTAssertEqual(backoff.next(), Backoff.initial)
    }

    // MARK: - A connection that goes away

    /// The first attempt is 250ms, so a couple of seconds is many times what
    /// this needs and still bounded.
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

    /// A server that hangs up on every client is a network that keeps dropping.
    /// The controller must keep trying rather than settle into a failure the
    /// user has to notice and act on.
    func testALostConnectionIsRetried() async throws {
        let server = try HangUpServer()
        defer { server.stop() }

        let controller = try TerminalController(
            terminalID: 1, host: .local(socketPath: server.path), cols: 80, rows: 24)
        defer { controller.disconnect() }
        controller.connect(cols: 80, rows: 24)

        try await waitFor("the first reconnect") { controller.state.isReconnecting }

        // And it keeps going: a second attempt, off the back of the first
        // retry finding the same closed door.
        try await waitFor("a second attempt") {
            if case .reconnecting(let attempt) = controller.state { return attempt >= 2 }
            return false
        }
        XCTAssertGreaterThanOrEqual(server.accepted, 2, "the retry never reached the socket")
    }

    /// Closing a pane must not leave a task waking up every thirty seconds to
    /// reconnect a terminal nobody is looking at.
    func testDisconnectStopsTheRetries() async throws {
        let server = try HangUpServer()
        defer { server.stop() }

        let controller = try TerminalController(
            terminalID: 1, host: .local(socketPath: server.path), cols: 80, rows: 24)
        controller.connect(cols: 80, rows: 24)
        try await waitFor("the first reconnect") { controller.state.isReconnecting }

        controller.disconnect()
        let accepted = server.accepted
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(server.accepted, accepted, "a retry survived disconnect()")
    }

    /// A host that is not there at all — no socket, no listener — is the same
    /// question as one that went away, and gets the same answer.
    func testAHostThatWasNeverThereIsRetried() async throws {
        let path = "/tmp/illogical-absent-\(getpid()).sock"
        unlink(path)
        let controller = try TerminalController(
            terminalID: 1, host: .local(socketPath: path), cols: 80, rows: 24)
        defer { controller.disconnect() }
        controller.connect(cols: 80, rows: 24)

        try await waitFor("a reconnect rather than a failure") {
            controller.state.isReconnecting
        }
    }

    /// A window resized while the connection was down must re-attach at the
    /// size it is *now*. The server sizes the PTY from the attach.
    func testAResizeDuringAnOutageIsCarriedIntoTheReattach() async throws {
        let server = try HangUpServer()
        defer { server.stop() }

        let controller = try TerminalController(
            terminalID: 1, host: .local(socketPath: server.path), cols: 80, rows: 24)
        defer { controller.disconnect() }
        controller.connect(cols: 80, rows: 24)
        try await waitFor("the first reconnect") { controller.state.isReconnecting }

        controller.resize(cols: 120, rows: 40)
        try await waitFor("an attach at the new size") {
            server.lastAttach == AttachSize(cols: 120, rows: 40)
        }
    }

    /// The host's control connection recovers the same way, and keeps the last
    /// session list while it does — clearing it would take every tab on that
    /// machine with it through the reconcile, over a dropped packet.
    func testAHostKeepsItsTerminalsWhileReconnecting() async throws {
        let server = try HangUpServer()
        defer { server.stop() }

        let store = SessionStore(hosts: [.local(socketPath: server.path)])
        guard let host = store.host(.local(socketPath: server.path)) else {
            return XCTFail("no host")
        }
        host.sessions = [SessionSummary(id: 1, name: "s", terminals: [1])]
        host.terminals = [
            TerminalSummary(
                id: 1, session: 1, name: "t1", command: "/bin/zsh", cwd: "/", cols: 80,
                rows: 24, residency: .live, attached: 0, ptyReadIdleNanoseconds: 0)
        ]
        store.reconcileTabs()
        XCTAssertEqual(store.tabs.count, 1)

        host.connect()
        try await waitFor("the host to be reconnecting") {
            if case .reconnecting = host.status { return true }
            return false
        }

        XCTAssertEqual(store.tabs.count, 1, "a dropped packet closed a tab")
        XCTAssertEqual(host.terminals.count, 1)
        // `connectionError` *is* set -- this is the only host and it is not
        // connected. What stops the window being taken over is that a tab wins
        // over the error in `ContentView`, which this test cannot reach; the
        // property asserted here is that the tab is still there to win.
        XCTAssertNotNil(store.connectionError)
        XCTAssertNotNil(store.selectedTab)
    }

    /// A pump belonging to a *replaced* connection must not tear down its
    /// successor. Reachable without any network fault: the server answers
    /// `no_such_terminal` and keeps the connection, so a pane sits in `.failed`
    /// with a live pump, and pressing Retry used to open a connection and then
    /// let the old pump abort its snapshot and close it.
    func testARetryIsNotUndoneByThePreviousConnection() async throws {
        let server = try HangUpServer()
        defer { server.stop() }

        let controller = try TerminalController(
            terminalID: 1, host: .local(socketPath: server.path), cols: 80, rows: 24)
        defer { controller.disconnect() }
        controller.connect(cols: 80, rows: 24)
        try await waitFor("the first reconnect") { controller.state.isReconnecting }

        let before = server.accepted
        controller.retryNow()
        // The retry must reach the socket and then *stay*: if the superseded
        // pump's tail still spoke for the controller it would close this one
        // and drop back into the backoff without another accept.
        try await waitFor("the retry to connect") { server.accepted > before }
        let afterRetry = server.accepted
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            server.accepted, afterRetry,
            "a superseded pump tore down the connection its retry had just made")
    }

    /// A host that recovers must start its next outage at the bottom of the
    /// backoff, not where the last one left off. Without the reset, eight flaky
    /// drops left the dropdown pinned at the 30-second ceiling for the life of
    /// the process while the panes came back in 250ms.
    func testAHostsBackoffIsForgivenOnceItIsListed() async throws {
        let server = try HangUpServer()
        defer { server.stop() }

        let store = SessionStore(hosts: [.local(socketPath: server.path)])
        guard let host = store.host(.local(socketPath: server.path)) else {
            return XCTFail("no host")
        }
        host.connect()
        try await waitFor("a few failed attempts") {
            if case .reconnecting(let attempt, _) = host.status { return attempt >= 3 }
            return false
        }

        // A `session_list` is what proves the connection works, and it is where
        // the backoff is forgiven.
        host.setStatusForTesting(.connected)
        host.applyListForTesting(sessions: [], terminals: [])
        XCTAssertEqual(Backoff.delay(forAttempt: 0), Backoff.initial)

        host.connect()
        try await waitFor("a first attempt again") {
            if case .reconnecting(let attempt, _) = host.status { return attempt == 1 }
            return false
        }
    }

    /// Not every failure is worth retrying every thirty seconds forever. `ssh`
    /// missing from PATH will not fix itself, and before this nothing ever
    /// assigned `.failed`, so it showed an amber "reconnecting…" indefinitely
    /// and rescanned PATH on a timer.
    func testAnUnrecoverableFailureIsTerminal() async throws {
        let store = SessionStore(hosts: [.ssh(destination: "nowhere")])
        guard let host = store.host(.ssh(destination: "nowhere")) else {
            return XCTFail("no host")
        }
        // `ILLOGICAL_SSH` is read by `sshOptions`, so pointing it at something
        // that is not on PATH reaches `TransportError.notOnPath`.
        setenv("ILLOGICAL_SSH", "illogical-no-such-ssh-binary", 1)
        defer { unsetenv("ILLOGICAL_SSH") }

        host.connect()
        try await waitFor("a terminal failure") {
            if case .failed = host.status { return true }
            return false
        }
        // ...and it stays failed rather than sliding back into the backoff.
        try await Task.sleep(for: .milliseconds(400))
        if case .failed = host.status {} else { XCTFail("a hopeless host went back to retrying") }
    }
}

struct AttachSize: Equatable, Sendable {
    var cols: UInt16
    var rows: UInt16
}

/// A unix socket that accepts a connection, reads whatever the client sends,
/// and hangs up. Stands in for a network that keeps dropping.
///
/// It records the `attach` it saw, so a test can assert what the client asked
/// for rather than only that it asked.
///
/// Deliberately *not* `@MainActor`, unlike everything else in the client: its
/// accept loop runs on a thread of its own, and a main-actor-isolated method
/// called from there trips the executor assertion and takes the test runner
/// down with it. Everything mutable is behind `State`'s lock instead.
final class HangUpServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _accepted = 0
        private var _lastAttach: AttachSize?
        private var _stopped = false

        var accepted: Int {
            lock.lock()
            defer { lock.unlock() }
            return _accepted
        }
        var lastAttach: AttachSize? {
            lock.lock()
            defer { lock.unlock() }
            return _lastAttach
        }
        var stopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _stopped
        }
        func stop() {
            lock.lock()
            defer { lock.unlock() }
            _stopped = true
        }
        func record(accepted: Bool = false, attach: AttachSize? = nil) {
            lock.lock()
            defer { lock.unlock() }
            if accepted { _accepted += 1 }
            if let attach { _lastAttach = attach }
        }
    }

    var accepted: Int { state.accepted }
    var lastAttach: AttachSize? { state.lastAttach }

    init() throws {
        path = "/tmp/illogical-hangup-\(getpid())-\(UInt32.random(in: 0..<1_000_000)).sock"
        unlink(path)

        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw TransportError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 16) == 0 else {
            Darwin.close(listener)
            throw TransportError.connectFailed(errno)
        }

        let fd = listener
        let state = self.state
        let thread = Thread { HangUpServer.accept(fd, state) }
        thread.name = "illogical.test.hangup"
        thread.start()
    }

    private static func accept(_ listener: Int32, _ state: State) {
        while !state.stopped {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 { return }
            state.record(accepted: true)
            // Read one round of frames -- `hello` then `attach` -- so the
            // client's request is observable, then hang up mid-handshake,
            // which is what a network going away looks like from here.
            readFrames(client, state)
            Darwin.close(client)
        }
    }

    private static func readFrames(_ fd: Int32, _ state: State) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending: [UInt8] = []
        // Two frames is all a client sends before it waits: hello, attach.
        for _ in 0..<2 {
            while pending.count < Protocol.headerLength {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 4096) }
                if n <= 0 { return }
                pending.append(contentsOf: buffer[0..<n])
            }
            guard let header = try? FrameHeader.decode(pending) else { return }
            let total = Protocol.headerLength + Int(header.length)
            while pending.count < total {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 4096) }
                if n <= 0 { return }
                pending.append(contentsOf: buffer[0..<n])
            }
            let payload = Data(pending[Protocol.headerLength..<total])
            pending.removeFirst(total)
            if header.type == .attach,
                let body = try? JSONDecoder().decode(AttachBody.self, from: payload)
            {
                state.record(attach: AttachSize(cols: body.cols, rows: body.rows))
            }
        }
    }

    func stop() {
        state.stop()
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(path)
    }
}
