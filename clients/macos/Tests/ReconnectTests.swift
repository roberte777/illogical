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
            terminalID: 1, host: .local(socketPath: server.path), size: .test(cols: 80, rows: 24))
        defer { controller.disconnect() }
        controller.connect(.test(cols: 80, rows: 24))

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
            terminalID: 1, host: .local(socketPath: server.path), size: .test(cols: 80, rows: 24))
        controller.connect(.test(cols: 80, rows: 24))
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
            terminalID: 1, host: .local(socketPath: path), size: .test(cols: 80, rows: 24))
        defer { controller.disconnect() }
        controller.connect(.test(cols: 80, rows: 24))

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
            terminalID: 1, host: .local(socketPath: server.path), size: .test(cols: 80, rows: 24))
        defer { controller.disconnect() }
        controller.connect(.test(cols: 80, rows: 24))
        try await waitFor("the first reconnect") { controller.state.isReconnecting }

        controller.resize(.test(cols: 120, rows: 40))
        try await waitFor("an attach at the new size") {
            server.lastAttach
                == AttachSize(cols: 120, rows: 40, cellWidth: 16, cellHeight: 38)
        }
    }

    /// The cell travels with the grid, and a reattach carries it too.
    ///
    /// Not a detail: the server has no font, so what it tells a program that
    /// asked for its size in pixels — DEC mode 2048, or `ws_xpixel` — is
    /// whatever the last client said a cell was. Send zeros and Neovim is told
    /// the terminal is zero pixels wide.
    func testAnAttachCarriesTheCellItMeasuredWith() async throws {
        let server = try HangUpServer()
        defer { server.stop() }

        let controller = try TerminalController(
            terminalID: 1, host: .local(socketPath: server.path),
            size: SurfaceSize(cols: 80, rows: 24, cell: CellSize(width: 9, height: 19)))
        defer { controller.disconnect() }
        controller.connect(
            SurfaceSize(cols: 80, rows: 24, cell: CellSize(width: 9, height: 19)))

        try await waitFor("an attach carrying the cell") {
            server.lastAttach
                == AttachSize(cols: 80, rows: 24, cellWidth: 9, cellHeight: 19)
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
        // `.errorThenHold`, not the hang-up server: a connection that has
        // already closed has already run its tail, so a retry on top of it
        // never has a superseded pump to be torn down by, and the test passes
        // whether or not the guard exists. The point of the error-and-hold is
        // that connection A is still *open* -- and its pump still running --
        // at the moment Retry opens B.
        let server = try HangUpServer(mode: .errorThenHold)
        defer { server.stop() }

        let controller = try TerminalController(
            terminalID: 1, host: .local(socketPath: server.path), size: .test(cols: 80, rows: 24))
        defer { controller.disconnect() }
        controller.connect(.test(cols: 80, rows: 24))
        try await waitFor("the pane to fail with its socket still up") {
            if case .failed = controller.state { return true }
            return false
        }
        XCTAssertEqual(server.accepted, 1)

        controller.retryNow()
        try await waitFor("the retry to connect") { server.accepted == 2 }

        // Connection B is now current and A -- closed by `openConnection` --
        // is running its tail. Well past the 250ms first backoff, so a
        // reconnect scheduled by that tail has had time to land *and* to be
        // answered, which is what the accept count would show.
        //
        // The accept count is the whole assertion. A state check would not
        // help: the unguarded tail schedules a reconnect, the retry fires at
        // 250ms, connection C gets the same `err` and lands back in `.failed`,
        // so by any later moment the state is identical either way. Only the
        // extra accept survives.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(
            server.accepted, 2,
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
        defer { host.disconnect() }
        host.connect()
        try await waitFor("a few failed attempts") {
            if case .reconnecting(let attempt, _) = host.status { return attempt >= 3 }
            return false
        }
        XCTAssertGreaterThanOrEqual(host.backoffAttemptForTesting, 3)

        // A `session_list` is what proves the connection works, and it is where
        // the backoff is forgiven. Driven as a real frame through the real
        // handler: an `applyListForTesting` that reset the backoff itself
        // stood here, and the only line whose deletion failed this test was
        // that helper's own `reset()` -- so the production one could be
        // deleted with the suite still green, which is the whole regression
        // this test is named for.
        //
        // Asserted on the counter rather than on the next
        // `.reconnecting(attempt:)`, because reaching that needs another
        // `connect()`, which resets the backoff too. No `await` between these
        // two lines: the retry task is on this actor, so nothing can advance
        // the backoff underneath the check.
        host.handleForTesting(
            Frame(
                type: .sessionList, terminal: Protocol.controlSession,
                payload: Data(#"{"sessions":[],"terminals":[]}"#.utf8)))
        XCTAssertTrue(host.status.isConnected, "a session_list did not land")
        XCTAssertEqual(
            host.backoffAttemptForTesting, 0,
            "a host that came back kept the backoff from the outage it recovered from")
    }

    /// The control connection has the same guard as the pane's, and until now
    /// nothing reached it: `handleForTesting` goes straight to `apply`, and the
    /// helper it replaced bypassed it too. What it prevents is a `session_list`
    /// buffered on a superseded connection — `close()` drains the stream to its
    /// end — overwriting the lists the *new* connection has just published, and
    /// reporting `.connected` for a machine still mid-handshake.
    func testAListFromAReplacedControlConnectionIsIgnored() async throws {
        let server = try HangUpServer()
        defer { server.stop() }

        let store = SessionStore(hosts: [.local(socketPath: server.path)])
        guard let host = store.host(.local(socketPath: server.path)) else {
            return XCTFail("no host")
        }
        defer { host.disconnect() }

        // Never installed as this host's control connection, so the guard must
        // send it home. Comparing identity is all the guard does.
        let stale = try Connection(host: .local(socketPath: server.path))
        defer { stale.close() }
        host.handleForTesting(
            Frame(
                type: .sessionList, terminal: Protocol.controlSession,
                payload: Data(
                    #"{"sessions":[{"id":1,"name":"ghost","terminals":[]}],"terminals":[]}"#
                        .utf8)
            ),
            from: stale)

        XCTAssertTrue(
            host.sessions.isEmpty,
            "a superseded connection's session_list overwrote the current one's")
        XCTAssertFalse(
            host.status.isConnected,
            "a superseded connection's session_list reported the host connected")
    }

    /// A `create` outstanding when the control connection drops is never going
    /// to be answered, and must not stay in the queue: replies are matched to
    /// requests by position, so one stranded entry lands every later split in
    /// the tab before last, for the life of the process.
    ///
    /// The dropped-connection path, specifically. `disconnect()` is covered in
    /// TabReconcileTests without a socket; this one needs a real connection to
    /// really close.
    func testACreateOutstandingWhenTheConnectionDropsIsVoided() async throws {
        let server = try HangUpServer()
        defer { server.stop() }

        let store = SessionStore(hosts: [.local(socketPath: server.path)])
        guard let host = store.host(.local(socketPath: server.path)) else {
            return XCTFail("no host")
        }
        defer { host.disconnect() }

        host.sessions = [SessionSummary(id: 1, name: "s", terminals: [1, 2])]
        host.terminals = [1, 2].map {
            TerminalSummary(
                id: $0, session: 1, name: "t\($0)", command: "/bin/zsh", cwd: "/",
                cols: 80, rows: 24, residency: .live, attached: 0, ptyReadIdleNanoseconds: 0)
        }
        store.reconcileTabs()
        XCTAssertEqual(store.tabs.count, 2)
        let first = store.tabs[0]
        let second = store.tabs[1]

        // Connect *first*, then ask. Asking first would have the entry voided
        // by `closeControl` inside `connect()` itself, and the test would pass
        // with the line it is named for deleted -- which is exactly what the
        // first version of it did. This way the create goes out on a live
        // connection and only `controlClosed` can retire it.
        host.connect()
        store.split(pane: first.panes[0].id, in: first.id, direction: .columns)

        // The server reads the handshake and hangs up, which is what runs
        // `controlClosed`: the path under test.
        try await waitFor("the control connection to drop") {
            if case .reconnecting = host.status { return true }
            return false
        }

        store.split(pane: second.panes[0].id, in: second.id, direction: .columns)
        store.host(.local(socketPath: server.path))?.onCreated?(12)
        XCTAssertEqual(
            store.tabs.first { $0.id == second.id }?.panes.count, 2,
            "a create orphaned by a dropped connection shifted the queue")
    }

    /// A frame buffered on a connection that has since been replaced must not
    /// be applied to its successor. `close()` finishes the stream but still
    /// delivers what is already in it, so an `exited` in flight when a pane
    /// reattaches used to land on the new connection — and `scheduleReconnect`
    /// refuses to act on `.exited`, so the pane stayed dead, with no retry,
    /// while the terminal ran on happily on the server.
    func testAFrameFromAReplacedConnectionIsIgnored() async throws {
        let server = try HangUpServer(mode: .errorThenHold)
        defer { server.stop() }

        let controller = try TerminalController(
            terminalID: 1, host: .local(socketPath: server.path), size: .test(cols: 80, rows: 24))
        defer { controller.disconnect() }
        controller.connect(.test(cols: 80, rows: 24))
        try await waitFor("the pane to attach") { server.accepted == 1 }

        // A second, unstarted connection stands in for the superseded one: what
        // the guard compares is identity, and this is not the controller's.
        let stale = try Connection(host: .local(socketPath: server.path))
        defer { stale.close() }
        controller.handleForTesting(
            Frame(type: .exited, terminal: 1, payload: Data(#"{"code":0}"#.utf8)), from: stale)

        if case .exited = controller.state {
            XCTFail("a stale `exited` killed a pane whose terminal is still running")
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

    /// The other half of that judgement: a spawn failure that is about the
    /// *file* — not there, not executable, not a program — is permanent, and
    /// must not become an amber "reconnecting…" that rescans it every thirty
    /// seconds for the life of the process.
    ///
    /// Which side a spawn failure falls on is decided by the errno, in
    /// `CommandTransport.spawnError`, and pinned there. What this covers is
    /// that `HostConnection` acts on that verdict — and that the string it
    /// puts in front of a person is a sentence rather than an `NSError` dump.
    func testAnUnrunnableSshIsTerminal() async throws {
        let store = SessionStore(hosts: [.ssh(destination: "nowhere")])
        guard let host = store.host(.ssh(destination: "nowhere")) else {
            return XCTFail("no host")
        }
        defer { host.disconnect() }

        // Exists and cannot be executed, so this reaches `Process.run()` --
        // `resolve` returns any argument containing a slash unexamined, so it
        // does not stop at `.notOnPath` on the way.
        let blocked = "/tmp/illogical-unspawnable-\(getpid())-\(UInt32.random(in: 0..<1_000_000))"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: blocked, contents: Data(), attributes: [.posixPermissions: 0o644]))
        defer { try? FileManager.default.removeItem(atPath: blocked) }
        setenv("ILLOGICAL_SSH", blocked, 1)
        defer { unsetenv("ILLOGICAL_SSH") }

        host.connect()
        try await waitFor("a verdict either way") {
            if case .connecting = host.status { return false }
            return true
        }
        guard case .failed(let message) = host.status else {
            return XCTFail("an ssh that cannot be run was left retrying: \(host.status)")
        }
        XCTAssertFalse(
            message.contains("NSCocoaErrorDomain") || message.contains("UserInfo="),
            "an NSError dump was put in front of a person: \(message)")
        // And it says the *right* thing. This file is present and mode 0644,
        // so "is not there" would be the same wrong advice pointing the other
        // way -- which is what Foundation's own sentence says here, and what a
        // classification driven by its error code produced. Asserting only
        // "not a dump" let that through.
        XCTAssertTrue(
            message.contains("is not executable"),
            "a file that is present and unrunnable was described as something else: \(message)")
    }

    // MARK: - Starting a server

    /// A socket path nothing is listening on, and nothing ever was.
    private static func absentSocket() -> String {
        let path = "/tmp/illogical-nostart-\(getpid())-\(UInt32.random(in: 0..<1_000_000)).sock"
        unlink(path)
        return path
    }

    private func localStore(
        _ path: String, _ launcher: RecordingLauncher
    ) throws -> HostConnection {
        let store = SessionStore(hosts: [.local(socketPath: path)], launcher: launcher)
        return try XCTUnwrap(store.host(.local(socketPath: path)), "no host")
    }

    /// The premise of the whole change: running the app is enough. Nothing is
    /// listening, so the app starts a server and then connects to it over the
    /// socket like any other client.
    func testARefusedLocalSocketStartsAServer() async throws {
        let path = Self.absentSocket()
        let launcher = RecordingLauncher(.bindListener)
        defer { launcher.stop() }
        let host = try localStore(path, launcher)
        defer { host.disconnect() }

        host.connect()
        try await waitFor("a server to be started") { launcher.callCount == 1 }
        XCTAssertEqual(
            launcher.calls, [path],
            "the daemon was pointed at a socket other than the one the app is dialling")

        // And the app came back and connected. That second connect is the
        // shape the design is for: an ordinary `connect()` over the socket,
        // with no bridge and no child of ours in the middle.
        try await waitFor("the app to connect to it") { launcher.accepted >= 1 }

        // Exactly once, ever. The listener is there now, so the reconnect
        // after this stub hangs up finds it and has nothing left to start.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(launcher.callCount, 1, "a second server was started")
    }

    /// The one that must never fire. A daemon that accepts a connection and
    /// drops it is *there*, and it owns every terminal behind that socket —
    /// starting another would take the socket from it and orphan the lot. Only
    /// a refused connect means there is nothing running.
    func testAServerThatAcceptsAndDropsIsNeverStartedOver() async throws {
        let server = try HangUpServer()
        defer { server.stop() }
        let launcher = RecordingLauncher(.succeedSilently)
        let host = try localStore(server.path, launcher)
        defer { host.disconnect() }

        host.connect()
        try await waitFor("a few failed attempts") {
            if case .reconnecting(let attempt, _) = host.status { return attempt >= 2 }
            return false
        }
        XCTAssertEqual(
            launcher.callCount, 0, "a daemon that was answering the socket was started over")
    }

    /// A remote machine has no bundle of ours to start anything from, and
    /// `--ensure` on this Mac would start a daemon for the *local* socket in
    /// response to a remote failure. `ssh <host> illogicald --stdio` is what
    /// starts a server over there, and it already does.
    func testARemoteHostNeverStartsALocalServer() async throws {
        let launcher = RecordingLauncher(.succeedSilently)
        let store = SessionStore(hosts: [.ssh(destination: "nowhere")], launcher: launcher)
        let host = try XCTUnwrap(store.host(.ssh(destination: "nowhere")), "no host")
        defer { host.disconnect() }
        setenv("ILLOGICAL_SSH", "illogical-no-such-ssh-binary", 1)
        defer { unsetenv("ILLOGICAL_SSH") }

        host.connect()
        try await waitFor("a verdict either way") {
            if case .connecting = host.status { return false }
            return true
        }
        XCTAssertEqual(launcher.callCount, 0)
    }

    /// A server that will not start says why, names the log that has the rest,
    /// and is not tried again on every backoff tick — which at 250ms would be
    /// four forks a second against a machine already in trouble.
    func testAServerThatWillNotStartSaysWhyAndIsNotRetriedEveryTick() async throws {
        let path = Self.absentSocket()
        let launcher = RecordingLauncher(
            .fail(.failed(socket: path, status: 1, stderr: "could not open the park store")))
        let host = try localStore(path, launcher)
        defer { host.disconnect() }

        host.connect()
        try await waitFor("the daemon's own words to reach the status") {
            host.status.message?.contains("could not open the park store") == true
        }
        // The daemon's stderr is a line; `daemon.log` beside the socket is
        // where the rest of it is, and naming it is most of what this sentence
        // can usefully do.
        XCTAssertTrue(
            host.status.message?.contains("daemon.log") == true,
            "the daemon's log was not named: \(host.status.message ?? "nil")")

        let after = launcher.callCount
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(
            launcher.callCount, after, "a server was started again on the backoff's own schedule")
    }

    /// The daemon's sentence is the whole point of it writing one, and it has
    /// to survive longer than a person takes to read it. The backoff retries
    /// 250 ms later, finds the socket still refusing, and used to overwrite the
    /// reason with the generic "No server at <path>" for the rest of the
    /// outage -- so the one line saying *which* directory is unwritable was on
    /// screen for a quarter of a second and then gone.
    func testTheReasonAServerWouldNotStartSurvivesTheBackoff() async throws {
        let path = Self.absentSocket()
        let launcher = RecordingLauncher(
            .fail(
                .failed(
                    socket: path, status: 1,
                    stderr: "illogicald --ensure: cannot write to /nonexistent-root-dir/x, "
                        + "where the socket and daemon.log live")))
        let host = try localStore(path, launcher)
        defer { host.disconnect() }

        host.connect()
        try await waitFor("the daemon's own words to reach the status") {
            host.status.message?.contains("cannot write to /nonexistent-root-dir/x") == true
        }
        // Past the first retry and several after it: the attempt counter only
        // rises on a reconnect that has been scheduled, so this is the flow
        // that used to do the overwriting, driven through the real thing.
        try await waitFor("several backoff ticks") {
            if case .reconnecting(let attempt, _) = host.status { return attempt >= 3 }
            return false
        }
        let message = host.status.message ?? "nil"
        XCTAssertTrue(
            message.contains("cannot write to /nonexistent-root-dir/x"),
            "the reason was replaced by the generic sentence: \(message)")
        XCTAssertFalse(
            message.contains("No server at"),
            "the symptom was put in front of a person instead of the reason: \(message)")
    }

    /// And it names the log once, or not at all. The daemon's line is
    /// self-contained -- socket, reason and log -- so the app appending its own
    /// derived `daemon.log` either says it twice or, for an unwritable state
    /// directory, points at a file that by definition cannot be there.
    func testTheDaemonsLogIsNotNamedTwiceNorInventedInAnUnwritableDirectory() async throws {
        let path = Self.absentSocket()
        let launcher = RecordingLauncher(
            .fail(
                .failed(
                    socket: path, status: 1,
                    stderr: "illogicald --ensure: cannot write to /nonexistent-root-dir/x, "
                        + "where the socket and daemon.log live")))
        let host = try localStore(path, launcher)
        defer { host.disconnect() }

        host.connect()
        try await waitFor("the daemon's own words to reach the status") {
            host.status.message?.contains("cannot write to") == true
        }
        let message = host.status.message ?? "nil"
        XCTAssertEqual(
            message.components(separatedBy: "daemon.log").count - 1, 1,
            "the log was named more than once: \(message)")
        // The socket here is in /tmp, so the log the app would derive is
        // /tmp/daemon.log -- a real, writable directory, and the wrong answer.
        XCTAssertFalse(
            message.contains("/tmp/daemon.log"),
            "a log in a different directory from the daemon's was named: \(message)")
    }

    /// The other half of that rule: when the daemon left nothing to quote, the
    /// app's derived path is all there is and must still be said. A timeout is
    /// the case with no sentence at all behind it.
    func testAStartWithNothingToQuoteStillNamesTheLog() async throws {
        let path = Self.absentSocket()
        let launcher = RecordingLauncher(.fail(.timedOut(socket: path, after: .seconds(15))))
        let host = try localStore(path, launcher)
        defer { host.disconnect() }

        host.connect()
        try await waitFor("the timeout to reach the status") {
            host.status.message?.contains("did not start a server") == true
        }
        XCTAssertTrue(
            host.status.message?.contains("/tmp/daemon.log") == true,
            "no log was named at all: \(host.status.message ?? "nil")")
    }

    /// ...but asking explicitly does try again. Try Again is a person saying
    /// "and this time start one if you have to".
    func testTryAgainAsksForAServerAgain() async throws {
        let path = Self.absentSocket()
        let launcher = RecordingLauncher(.fail(.timedOut(socket: path, after: .seconds(15))))
        let host = try localStore(path, launcher)
        defer { host.disconnect() }

        host.connect()
        try await waitFor("the first attempt") { launcher.callCount == 1 }
        host.connect()
        try await waitFor("a second attempt") { launcher.callCount == 2 }
    }

    /// One spawn per outage, and a `session_list` is what ends an outage. A
    /// daemon that started, answered, and later died must be startable again —
    /// otherwise the first crash of the day is the last server of the day.
    func testANewOutageMayStartAServerAgain() async throws {
        let path = Self.absentSocket()
        // Reports success and binds nothing, which is what a daemon that
        // starts and immediately dies looks like from out here.
        let launcher = RecordingLauncher(.succeedSilently)
        let host = try localStore(path, launcher)
        defer { host.disconnect() }
        // Below the 700 ms this test already waits, so the `session_list` that
        // ends the outage arrives against a server that has *outlived* its
        // probation. That is the other half of the rule the test below states:
        // a daemon which ran long enough may be replaced.
        host.minimumServerLifetime = .milliseconds(300)

        host.connect()
        try await waitFor("the first start") { launcher.callCount == 1 }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(launcher.callCount, 1, "the backoff was forking a daemon a tick")

        // The frame that proves the far end is real. Driven through the real
        // handler for the same reason the backoff test drives it: the reset
        // has to be the production line, not a test's own copy of it.
        host.handleForTesting(
            Frame(
                type: .sessionList, terminal: Protocol.controlSession,
                payload: Data(#"{"sessions":[],"terminals":[]}"#.utf8)))
        XCTAssertTrue(host.status.isConnected, "a session_list did not land")

        // The retry already scheduled finds the socket still refusing, and
        // this time it is allowed to start one.
        try await waitFor("a start for the next outage") { launcher.callCount == 2 }
    }

    /// The hole in "one spawn per outage": a `session_list` ends the outage, so
    /// a daemon that starts, lists, and dies on its first attach re-arms the
    /// spawn on its way past and is replaced by an identical copy of itself
    /// three times a second, forever (REVIEW F7). A server this app started has
    /// to survive `minimumServerLifetime` before it earns a successor.
    func testAServerThatDiesRightAfterListingIsNotStartedAgainAndAgain() async throws {
        let path = Self.absentSocket()
        let launcher = RecordingLauncher(.succeedSilently)
        let host = try localStore(path, launcher)
        defer { host.disconnect() }

        host.connect()
        try await waitFor("the first start") { launcher.callCount == 1 }

        // The frame that used to be enough to earn a second spawn. Immediately,
        // so that the server is well inside the default ten-second window when
        // the retry below finds the socket refusing.
        host.handleForTesting(
            Frame(
                type: .sessionList, terminal: Protocol.controlSession,
                payload: Data(#"{"sessions":[],"terminals":[]}"#.utf8)))
        XCTAssertTrue(host.status.isConnected, "a session_list did not land")

        // The retry already scheduled (250 ms) finds the socket refusing.
        try await waitFor("the host to give up") {
            if case .failed(let message) = host.status { return message.contains("daemon.log") }
            return false
        }

        // And stays given up, rather than resuming the storm a tick later.
        try await Task.sleep(for: .milliseconds(700))
        if case .failed = host.status {} else { XCTFail("the host went back to retrying") }
        XCTAssertEqual(launcher.callCount, 1, "a second daemon was forked")

        // Try Again is the person saying "once more", and it is the only thing
        // that gets past this.
        host.connect()
        try await waitFor("Try Again to start one") { launcher.callCount == 2 }
    }

    /// The refusal, over a real socket, against a daemon that keeps talking
    /// after it — which is what a daemon without branch 1's hang-up does, and
    /// what every daemon already deployed does. `VersionSkewTests` drives the
    /// same frames through `handleForTesting`; this one adds the connection, so
    /// `controlClosed` on the socket we hung up on is exercised too.
    ///
    /// This is the test that fails against the old code by going `.connected`.
    func testADaemonThatRefusesHelloAndKeepsTalkingIsStillTerminal() async throws {
        let server = try HangUpServer(mode: .refuseHello)
        defer { server.stop() }

        let launcher = RecordingLauncher(.succeedSilently)
        let host = try localStore(server.path, launcher)
        defer { host.disconnect() }

        host.connect()
        try await waitFor("the refusal to reach the status") {
            if case .failed(let message) = host.status { return message.contains("protocol") }
            return false
        }

        // The `session_list` behind the `err` has landed by now, and so has the
        // close. Neither may put the host back on its feet.
        try await Task.sleep(for: .milliseconds(700))
        if case .failed = host.status {} else { XCTFail("a refused daemon reconnected") }
        XCTAssertEqual(server.accepted, 1, "the client reconnected to a daemon that refused it")
        XCTAssertEqual(launcher.callCount, 0, "a refusal was mistaken for nothing listening")
    }

    /// The mirror is a replica, and its size is part of the state it
    /// replicates — so the window never sizes it and the stream always does.
    ///
    /// The point of the ordering is what a fast drag looked like without it:
    /// the mirror a size ahead of the bytes it was parsing, so a full-screen
    /// program's repaint for 200 columns wrapped into 180.
    func testTheStreamSizesTheMirrorAndTheWindowDoesNot() async throws {
        let server = try HangUpServer(mode: .errorThenHold)
        defer { server.stop() }

        let controller = try TerminalController(
            terminalID: 1, host: .local(socketPath: server.path), size: .test(cols: 80, rows: 24))
        defer { controller.disconnect() }
        controller.connect(.test(cols: 80, rows: 24))
        try await waitFor("the pane to attach") { server.accepted == 1 }

        controller.resize(.test(cols: 120, rows: 40))
        XCTAssertEqual(controller.engine.cols, 80, "the window sized the mirror")

        controller.handleForTesting(
            Frame(type: .resized, terminal: 1, payload: Data(#"{"cols":120,"rows":40}"#.utf8)))
        XCTAssertEqual(controller.engine.cols, 120)
        XCTAssertEqual(controller.engine.rows, 40)
    }

    /// A desync reattaches at the size the *window* is, not the size the
    /// mirror is. They differ by a round trip on purpose (above), and a
    /// resize is exactly what provokes the repaint burst that desyncs a
    /// client — so this is the ordinary case, not a corner. Attaching at the
    /// mirror's size moved the server back to it, and the size guard in
    /// `resize` then kept the window's size from ever being sent again.
    func testADesyncReattachesAtTheWindowsSize() async throws {
        let server = try HangUpServer(mode: .errorThenHold)
        defer { server.stop() }

        let controller = try TerminalController(
            terminalID: 1, host: .local(socketPath: server.path), size: .test(cols: 80, rows: 24))
        defer { controller.disconnect() }
        controller.connect(.test(cols: 80, rows: 24))
        try await waitFor("the first attach") {
            server.lastAttach == AttachSize(cols: 80, rows: 24, cellWidth: 16, cellHeight: 38)
        }

        // Sent, not yet answered: the mirror is still 80x24.
        controller.resize(.test(cols: 120, rows: 40))
        XCTAssertEqual(controller.engine.cols, 80)

        controller.handleForTesting(
            Frame(
                type: .error, terminal: 1,
                payload: Data(#"{"code":7,"message":"desync"}"#.utf8)))
        try await waitFor("a reattach at the window's size") {
            server.lastAttach == AttachSize(cols: 120, rows: 40, cellWidth: 16, cellHeight: 38)
        }
    }

}

/// A `DaemonLauncher` that starts nothing, and remembers being asked.
///
/// A lock rather than an actor, for the same reason `HangUpServer` is not
/// `@MainActor`: the assertions read the call count from `waitFor`'s
/// synchronous predicate, and an actor would turn every one of them into an
/// await inside a polling loop.
final class RecordingLauncher: DaemonLauncher, @unchecked Sendable {
    enum Behaviour: Sendable {
        /// Report success and bind nothing. A daemon that started and died.
        case succeedSilently
        /// Bind a real listener at the socket before returning, which is what
        /// a working `--ensure` leaves behind.
        case bindListener
        case fail(LocalDaemonError)
    }

    private let lock = NSLock()
    private var _calls: [String] = []
    private var _behaviour: Behaviour
    private var _server: HangUpServer?

    init(_ behaviour: Behaviour) { _behaviour = behaviour }

    /// The socket paths it was asked about, in order. The path matters as much
    /// as the count: a daemon started on the wrong socket is a daemon the app
    /// will never reach.
    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }
    var callCount: Int { calls.count }

    /// How many times something connected to the listener this stub bound.
    var accepted: Int {
        lock.lock()
        defer { lock.unlock() }
        return _server?.accepted ?? 0
    }

    func ensure(socketPath: String) async throws -> LocalDaemon.Outcome {
        // Every line of the work is in the synchronous helper below: `lock()`
        // and `unlock()` are unavailable from an async context, and this
        // protocol method is async because the real launcher waits for a
        // child.
        try answer(socketPath)
    }

    /// Nil, so nothing in this file ever compares versions. The skew notice is
    /// `VersionSkewTests`' subject; here it would only be noise on the status
    /// these tests assert against.
    func bundledVersion() async -> String? { nil }

    private func answer(_ socketPath: String) throws -> LocalDaemon.Outcome {
        lock.lock()
        _calls.append(socketPath)
        let behaviour = _behaviour
        lock.unlock()

        switch behaviour {
        case .succeedSilently:
            return .started
        case .bindListener:
            lock.lock()
            defer { lock.unlock() }
            if _server == nil { _server = try HangUpServer(path: socketPath) }
            return .started
        case .fail(let error):
            throw error
        }
    }

    func stop() {
        lock.lock()
        let server = _server
        _server = nil
        lock.unlock()
        server?.stop()
    }
}

struct AttachSize: Equatable, Sendable {
    var cols: UInt16
    var rows: UInt16
    /// The cell the client measured that grid with. Zero from a client that
    /// has no font of its own; the server quotes it back to any program that
    /// asked for a size in pixels, so a test that ignored it would not notice
    /// the whole thing going out at zero.
    var cellWidth: UInt32 = 0
    var cellHeight: UInt32 = 0
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
    /// What the server does once it has read the client's handshake.
    enum Mode: Sendable {
        /// Hang up. A network going away.
        case hangUp
        /// Answer with an `err` the client cannot recover from and then *hold
        /// the connection open*. This is what `no_such_terminal` looks like
        /// from the client: the pane lands in `.failed` with its socket still
        /// up and its pump still running, which is the only way to get a live
        /// superseded pump without a race.
        case errorThenHold
        /// Refuse the `hello` over the protocol version and then keep talking:
        /// `err(version_mismatch)` followed by a `session_list`, then close.
        /// That is what a daemon without branch 1's hang-up did, and it is the
        /// sequence a client pipelining `hello` and `list` really sees.
        case refuseHello
    }

    let path: String
    private let listener: Int32
    private let state = State()
    private let mode: Mode

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _accepted = 0
        private var _lastAttach: AttachSize?
        private var _stopped = false
        private var _held: [Int32] = []

        /// Keep a client fd open for the life of the server. Closed by `stop`,
        /// which is what keeps the test from leaking descriptors into the rest
        /// of the suite.
        func hold(_ fd: Int32) {
            lock.lock()
            defer { lock.unlock() }
            if _stopped {
                Darwin.close(fd)
                return
            }
            _held.append(fd)
        }

        /// The threads reading held sockets. `releaseHeld` waits for them
        /// between shutting a socket down and closing it: a close while a
        /// reader has yet to enter `read` frees the descriptor number for the
        /// next test's socket, and the stray reader then eats that socket's
        /// hello.
        let readers = DispatchGroup()

        func releaseHeld() {
            lock.lock()
            let fds = _held
            _held = []
            lock.unlock()
            // Shut down first: that is what wakes a reader blocked on the
            // socket, or makes one that has not started yet return at once.
            // Close only once every reader has left, so the number cannot be
            // reused under one.
            for fd in fds { Darwin.shutdown(fd, SHUT_RDWR) }
            readers.wait()
            for fd in fds { Darwin.close(fd) }
        }

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

    /// `path` names where to bind. Only the daemon-launcher tests pass one:
    /// they have to put a listener at the socket the client is *already*
    /// looking at, which is the whole shape of "start a server and connect
    /// again".
    init(mode: Mode = .hangUp, path: String? = nil) throws {
        self.mode = mode
        self.path =
            path ?? "/tmp/illogical-hangup-\(getpid())-\(UInt32.random(in: 0..<1_000_000)).sock"
        unlink(self.path)

        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw TransportError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(self.path.utf8)) }
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
        let mode = self.mode
        let thread = Thread { HangUpServer.accept(fd, state, mode) }
        thread.name = "illogical.test.hangup"
        thread.start()
    }

    private static func accept(_ listener: Int32, _ state: State, _ mode: Mode) {
        while !state.stopped {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 { return }
            // Belt and braces with the `spoke` check below: a write to a
            // socket whose peer has gone is a SIGPIPE, whose default
            // disposition kills the process -- and this one is the test
            // runner. `CommandTransport` sets SIG_IGN process-wide, but only
            // once something has built one, which most runs never do.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            state.record(accepted: true)
            // Read one round of frames -- `hello` then `attach` -- so the
            // client's request is observable. What happens next is the mode's:
            // hang up, which is what a network going away looks like from
            // here, or answer with an error and keep the socket, which is what
            // `no_such_terminal` looks like.
            let spoke = readFrames(client, state)
            switch mode {
            case .hangUp:
                Darwin.close(client)
            case .errorThenHold:
                // Only to a client that actually completed its handshake. A
                // connection opened and dropped without a word -- which one of
                // these tests does deliberately -- must not be written to.
                if spoke {
                    sendError(client, code: ProtocolErrorCode.noSuchSession, session: 1)
                    state.hold(client)
                    // Keep reading the held socket. A test that provokes a
                    // reattach on it wants the attach it sends recorded, and
                    // the accept loop must not be the thread that waits for
                    // it: the same tests open a second connection meanwhile.
                    state.readers.enter()
                    Thread.detachNewThread {
                        defer { state.readers.leave() }
                        _ = Self.readFrames(client, state, count: .max)
                    }
                } else {
                    Darwin.close(client)
                }
            case .refuseHello:
                if spoke {
                    sendError(
                        client, code: ProtocolErrorCode.versionMismatch,
                        session: Protocol.controlSession)
                    // The frame the client had already asked for, arriving
                    // behind the refusal because it was written before it.
                    sendFrame(
                        client, type: .sessionList, session: Protocol.controlSession,
                        payload: Data(#"{"sessions":[],"terminals":[]}"#.utf8))
                }
                Darwin.close(client)
            }
        }
    }

    /// An `err` this client will not try to recover from. Deliberately not
    /// `.desync`, which is the one code that means "attach again".
    private static func sendError(_ fd: Int32, code: ProtocolErrorCode, session: UInt64) {
        // The wire bytes, not an encoded `ErrBody`: these types are the
        // *client's* decoding of what a daemon sends, and only their
        // `Decodable` half is public. Standing in for the daemon means writing
        // what the daemon writes.
        let payload = Data(#"{"code":\#(code.rawValue),"message":"refused"}"#.utf8)
        sendFrame(fd, type: .error, session: session, payload: payload)
    }

    private static func sendFrame(
        _ fd: Int32, type: FrameType, session: UInt64, payload: Data
    ) {
        var frame = FrameHeader(
            type: type, session: session, length: UInt32(payload.count)
        ).encoded
        frame.append(payload)
        frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    /// True only if both frames arrived. The caller needs to tell that apart
    /// from a client that hung up or never spoke: writing an `err` back down a
    /// socket whose peer has gone raises SIGPIPE, and an accepted descriptor
    /// has no `SO_NOSIGPIPE` unless we set one -- which would take the whole
    /// test bundle down with a crash report rather than a failure.
    @discardableResult
    private static func readFrames(_ fd: Int32, _ state: State, count: Int = 2) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending: [UInt8] = []
        // Two frames is all a client sends before it waits: hello, attach.
        // `.max` reads until the far end hangs up.
        var read = 0
        while read < count {
            read += 1
            while pending.count < Protocol.headerLength {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 4096) }
                if n <= 0 { return false }
                pending.append(contentsOf: buffer[0..<n])
            }
            guard let header = try? FrameHeader.decode(pending) else { return false }
            let total = Protocol.headerLength + Int(header.length)
            while pending.count < total {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 4096) }
                if n <= 0 { return false }
                pending.append(contentsOf: buffer[0..<n])
            }
            let payload = Data(pending[Protocol.headerLength..<total])
            pending.removeFirst(total)
            if header.type == .attach,
                let body = try? JSONDecoder().decode(AttachBody.self, from: payload)
            {
                state.record(
                    attach: AttachSize(
                        cols: body.cols, rows: body.rows,
                        cellWidth: body.cellWidth, cellHeight: body.cellHeight))
            }
        }
        return true
    }

    func stop() {
        state.stop()
        state.releaseHeld()
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(path)
    }
}
