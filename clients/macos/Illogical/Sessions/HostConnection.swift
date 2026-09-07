//  HostConnection.swift
//  One machine: its control connection, its sessions, its terminals.
//
//  A window can hold several of these at once — the local daemon and any
//  number of remote ones — which is why nothing below is a singleton and why
//  terminals are addressed by `TerminalRef` rather than by id. Two machines
//  both have a terminal 1.
//
//  The control connection is separate from the per-terminal connections. It
//  carries list/create/kill only; terminal traffic never touches it. Over SSH
//  that means a window showing four splits on a remote host holds five
//  connections to it — one control and four terminals — which is what the
//  `ControlMaster` multiplexing in Transport.swift is for.

import Foundation
import IllogicalProtocol
import Observation

/// Identifies a terminal. A bare `UInt64` is not enough once a window can see
/// more than one machine.
struct TerminalRef: Hashable, Sendable {
    var host: ServerHost
    var terminal: UInt64
}

/// Identifies a session, for the same reason.
struct SessionRef: Hashable, Sendable {
    var host: ServerHost
    var session: UInt64
}

/// A daemon that is not the build this app shipped. Both strings, because the
/// only useful thing to say about it is which two they are.
struct VersionSkew: Equatable, Sendable {
    var server: String
    var shipped: String
}

/// What starts a local server when there is none.
///
/// A seam, and it exists for one reason: every test that reaches `connect()`
/// with a `.local` host would otherwise run the real thing, and the real thing
/// starts a daemon. `LocalDaemon.executable()` is nil in a test process so
/// nothing would actually spawn, but that is a property of the host process
/// rather than of the test, and it makes "was the launcher called?" -- which is
/// most of what there is to assert here -- unobservable.
protocol DaemonLauncher: Sendable {
    /// Make sure a daemon is listening on `socketPath`, or throw saying why
    /// not. Returns only once there is one.
    func ensure(socketPath: String) async throws -> LocalDaemon.Outcome

    /// The version of the daemon this app ships, to compare against the one it
    /// is actually talking to. Nil when there is none to ask, or when it did
    /// not answer -- a version we could not read is a comparison we do not
    /// make.
    func bundledVersion() async -> String?
}

/// The one the app uses: the `illogicald` inside this bundle.
struct BundledDaemonLauncher: DaemonLauncher {
    func ensure(socketPath: String) async throws -> LocalDaemon.Outcome {
        try await LocalDaemon.ensure(LocalDaemon.Options(socketPath: socketPath))
    }

    func bundledVersion() async -> String? {
        guard let executable = LocalDaemon.executable() else { return nil }
        return await LocalDaemon.version(executable: executable)
    }
}

@MainActor
@Observable
final class HostConnection: Identifiable {
    /// The host is its own identity: two `.ssh` entries for one destination
    /// are one machine, and there is no id to keep in step with anything.
    nonisolated let host: ServerHost
    /// `nonisolated` because `Identifiable` is not main-actor-isolated and
    /// SwiftUI reads it from wherever it likes. Safe: it is an immutable
    /// `Sendable` value fixed at init.
    nonisolated var id: ServerHost { host }

    enum Status: Equatable {
        case connecting
        case connected
        /// The connection went away and is being made again, carrying `ssh`'s
        /// own complaint where there is one. Deliberately not `failed`: a
        /// machine asleep, or behind a network that will come back, is the
        /// ordinary case rather than the exception.
        case reconnecting(attempt: Int, detail: String?)
        /// Given up on. Reached only by asking.
        case failed(String)

        /// The wording for a reconnect that has nothing better to say than the
        /// attempt number. A sentence, capitalized: it is shown as a tooltip
        /// and on the "no server" screen, both sentence-initial.
        static func reconnectingMessage(attempt: Int) -> String {
            "Reconnecting… (attempt \(attempt))"
        }

        /// What to put in front of a person. Nil only while there is nothing
        /// worth saying.
        var message: String? {
            switch self {
            case .connecting, .connected: nil
            case .reconnecting(let attempt, let detail):
                detail ?? Self.reconnectingMessage(attempt: attempt)
            case .failed(let message): message
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        /// Still trying, and nothing has gone wrong yet. Over SSH this covers
        /// the whole handshake — authentication, the remote spawn, the first
        /// list — which is a second or more, and much longer behind 2FA.
        ///
        /// Deliberately not true for `.reconnecting`: that one has a message
        /// worth showing, and something did go wrong.
        var isConnecting: Bool {
            if case .connecting = self { return true }
            return false
        }
    }

    /// Drive the status directly. Only for tests: the interesting states are
    /// otherwise reached by a connection actually failing, which needs a
    /// socket.
    func setStatusForTesting(_ next: Status) {
        setStatus(next)
    }

    /// How far into the backoff the *control* connection is. For tests: the
    /// reset lives on the `session_list` path rather than on the connect, and
    /// nothing else observes it -- the delay it produces is what a person
    /// sees, and a test cannot wait thirty seconds to notice it was not
    /// forgiven.
    var backoffAttemptForTesting: Int { backoff.attempt }

    /// Feed a frame as though the daemon had sent it, skipping only the
    /// identity check — a test has no `Connection` to be the current one.
    ///
    /// This replaced an `applyListForTesting` that reassigned the lists and
    /// reset the backoff itself. It looked like the wire path and was not: the
    /// only line whose deletion failed the backoff test was that helper's own
    /// `reset()`, so deleting the real one in `apply` left it green — a test
    /// pinning its own stand-in.
    func handleForTesting(_ frame: Frame) {
        apply(frame)
    }

    /// The same, but through the identity guard, so a test can hand it a
    /// connection that is not the current one.
    func handleForTesting(_ frame: Frame, from source: Connection) {
        handle(frame, from: source)
    }

    private(set) var status: Status = .connecting
    var sessions: [SessionSummary] = []
    var terminals: [TerminalSummary] = []

    /// What the daemon said it was, from `welcome.server`. Nil until the first
    /// welcome of the current connection.
    private(set) var serverVersion: String?

    /// The daemon answering this socket is not the one the app shipped.
    ///
    /// Local hosts only, and it blocks nothing. A version string carries the
    /// `vendor/ghostty` pin, which is what actually decides whether two builds
    /// agree about a snapshot -- but "different" is not "incompatible", a
    /// daemon somebody started by hand from another checkout usually works
    /// fine, and a snapshot that genuinely does not match already fails loudly
    /// at `snapshot_begin.format`. So this is a marker and a tooltip and
    /// nothing more: the running daemon owns the terminals, and the app does
    /// not get to end them over a string.
    private(set) var versionSkew: VersionSkew?

    /// Asked for once and remembered. Running `illogicald --version` is a
    /// process, and a reconnect loop would otherwise start one on every
    /// backoff tick. The flag is what distinguishes "not asked yet" from
    /// "asked, and there was no answer" -- without it, a bundle with no daemon
    /// in it re-runs the lookup on every welcome, forever.
    private var shippedVersion: String?
    private var askedForShippedVersion = false

    /// This daemon refused our protocol version, so nothing it says counts.
    ///
    /// The refusal arrives as one frame in a stream, and a client pipelines --
    /// `hello` and `list` go out back to back -- so the `session_list` the
    /// daemon queued behind the `err` was already on the wire. `apply` reads a
    /// `session_list` as "connected", which is how the app used to log the
    /// refusal and attach to the daemon 55 ms later (REVIEW F1). The daemon now
    /// hangs up after refusing, and this is the client's half of the same rule:
    /// once refused, this connection is over whatever else turns up on it.
    ///
    /// Cleared by `connect()` -- Try Again against a daemon somebody has since
    /// replaced is a reasonable thing to ask for.
    private var protocolRefused = false

    /// Live controllers, one per open terminal on this host.
    private(set) var controllers: [UInt64: TerminalController] = [:]

    private var control: Connection?
    private var pump: Task<Void, Never>?
    /// The retry in flight, and how far into the backoff we are.
    private var retry: Task<Void, Never>?
    private var backoff = Backoff()
    /// Set by `disconnect()`. A connection that closed because we closed it is
    /// not something to recover from.
    private var closedByUs = false

    /// Starts a local server when nothing is listening on the socket.
    private let launcher: DaemonLauncher
    /// The `--ensure` in flight, and which one it is.
    ///
    /// The epoch is the identity guard the pumps use, for the same reason: the
    /// Retry button and `disconnect()` both invalidate a start that is still
    /// waiting, and without it a child finishing after Retry would open a
    /// second control connection on top of the one Retry had just made.
    private var starting: Task<Void, Never>?
    private var startEpoch = 0
    /// Whether a server has already been started for *this* outage.
    ///
    /// At most one spawn per outage, and this is the whole of that rule. A
    /// daemon that starts and immediately dies leaves the socket refusing
    /// connections exactly as before, so without this every backoff tick would
    /// fork another one -- forever, at up to two a second while the backoff is
    /// still short. Cleared by the user asking again (`connect()`) and by a
    /// `session_list`, which is the frame that proves the outage is over --
    /// correctly, because a daemon that ran for a day and then died deserves a
    /// replacement. `minimumServerLifetime` is what stops that same rule from
    /// re-arming for a daemon that has been alive for 250 ms.

    // MARK: - Events, for the store that owns the layout
    //
    // The host knows what exists; the window knows where it is drawn. Keeping
    // that split is what lets the reconcile stay in one place across every
    // host rather than once per connection.

    /// The session/terminal list changed.
    var onListChanged: (() -> Void)?
    /// The server made a terminal, in reply to our `create`.
    var onCreated: ((UInt64) -> Void)?
    /// Give up on every `create` outstanding for this host. See
    /// `voidPendingCreates`, which is exact about when that is a fact and when
    /// it is the safe assumption.
    var onCreatesVoided: (() -> Void)?

    private var startedThisOutage = false

    /// When the server this app started came up, or nil if it did not start
    /// one that is still notionally alive.
    ///
    /// Set on the connect that follows a successful `--ensure`, cleared by the
    /// user asking again. Read only by `openControl`'s catch, against
    /// `minimumServerLifetime`.
    private var serverCameUpAt: ContinuousClock.Instant?

    /// How long a server this app started must survive before this app will
    /// start another one for it.
    ///
    /// "One spawn per outage" ends an outage at `session_list`, and that is a
    /// hole: a daemon that starts, lists and then dies on its first attach --
    /// a corrupt park file, a full disk on `park.key` -- clears
    /// `startedThisOutage` on its way past, so the 250 ms retry finds the
    /// socket refusing and forks another one. Three forks a second of a 10 MB
    /// binary, forever, each appending to the same log: the storm R2 exists to
    /// prevent, reached by a different route (REVIEW F7).
    ///
    /// A `var` so tests can lower it; nothing in the app writes it.
    var minimumServerLifetime: Duration = .seconds(10)

    init(host: ServerHost, launcher: DaemonLauncher = BundledDaemonLauncher()) {
        self.host = host
        self.launcher = launcher
    }

    var displayName: String { host.displayName }

    func terminal(_ id: UInt64) -> TerminalSummary? {
        terminals.first { $0.id == id }
    }

    func ref(_ id: UInt64) -> TerminalRef { TerminalRef(host: host, terminal: id) }

    // MARK: - Control connection

    /// Connect, or try again now rather than when the backoff says to. What
    /// the dropdown's retry button does.
    func connect() {
        closedByUs = false
        retry?.cancel()
        retry = nil
        // Somebody pressed Try Again, which is a person saying "and this time
        // start one if you have to". A start still in flight from the last
        // attempt is superseded rather than joined: it would open a second
        // control connection on top of the one below.
        cancelStart()
        protocolRefused = false
        startedThisOutage = false
        // Try Again is a person saying "once more", which is the one thing
        // that gets past the lifetime rule below.
        serverCameUpAt = nil
        backoff.reset()
        openControl()
    }

    private func openControl() {
        closeControl()
        setStatus(.connecting)
        Trace.log("connecting to \(host.displayName)")
        do {
            let connection = try Connection(host: host)
            control = connection
            connection.start()
            try connection.send(.hello, json: HelloBody(client: "Illogical.app"))
            // Not `.connected` yet. For an ssh host `CommandTransport` has
            // only *spawned* the process at this point -- nothing about
            // authentication or reachability is known, and the write above
            // lands in a pipe. The `session_list` below is the first thing
            // that proves the far end is really there, and `selectedHost`
            // routes new terminals on this.

            pump = Task { [weak self] in
                for await frame in connection.frames {
                    guard let self else { return }
                    await self.handle(frame, from: connection)
                }
                await self?.controlClosed(connection)
            }
            refresh()
            Trace.log("control connection to \(host.displayName) open")
        } catch let error as TransportError {
            Trace.log("connect to \(host.displayName) failed: \(error)")
            // Nothing is listening on the local socket, and this app carries a
            // server. Start one and come back here -- the connect above is
            // then an ordinary one, over the socket, with no bridge and no
            // child of ours in the middle. `.connecting` is left standing
            // while that happens, which is the one status the "no server"
            // screen does not take over for.
            if canStartLocalServer(after: error) {
                // A server we started, that died inside its first few seconds.
                // Starting another would only produce another corpse, so stop
                // and say where the reason is written down. Try Again clears
                // this.
                if case .local(let path) = host, let cameUp = serverCameUpAt,
                    cameUp.duration(to: .now) < minimumServerLifetime
                {
                    retry?.cancel()
                    retry = nil
                    setStatus(
                        .failed(
                            "The server this app started on \(path) exited within "
                                + "\(minimumServerLifetime) of starting, and is not being started "
                                + "again. Its log is \(Self.daemonLogPath(forSocket: path))."))
                    return
                }
                startedThisOutage = true
                startLocalServer()
                return
            }
            // Some failures are not worth retrying every thirty seconds for
            // the life of the process. `ssh` missing from PATH, a socket path
            // that does not fit in `sockaddr_un`, a shebang that is not a
            // program: none will fix itself, and showing one as an amber
            // "reconnecting…" forever -- while rescanning PATH on a timer --
            // tells the user nothing. This is what makes `.failed` reachable;
            // before it, nothing ever set it.
            //
            // The error decides, rather than a list repeated here. Which side
            // a *spawn* failure falls on is not knowable from the case: it is
            // `EMFILE` -- three descriptors per remote connection, so a window
            // with enough panes reaches it and one closing clears it -- as
            // readily as it is a broken image. `TransportError` keeps the
            // errno for exactly this.
            if error.isTransient {
                scheduleReconnect(detail: describe(error))
            } else {
                setStatus(.failed(describe(error)))
            }
        } catch {
            Trace.log("connect to \(host.displayName) failed: \(error)")
            scheduleReconnect(detail: describe(error))
        }
    }

    /// Tear the connection down, leaving the retry machinery alone.
    private func closeControl() {
        pump?.cancel()
        pump = nil
        control?.close()
        control = nil
        // Both are facts about the daemon on the other end of a connection
        // that has gone. The next `welcome` establishes them again -- and it
        // may well be a different daemon, which is the whole point of noticing.
        serverVersion = nil
        versionSkew = nil
        // Here rather than only in `disconnect`, because `openControl` comes
        // through here too and a reconnect is the commonest way a `create`
        // stops being answerable. The cancelled pump's own tail cannot do it:
        // `control` has already been replaced by the time it runs, so its
        // identity guard sends it home.
        voidPendingCreates()
    }

    func disconnect() {
        closedByUs = true
        retry?.cancel()
        retry = nil
        cancelStart()
        closeControl()
        for id in controllers.keys { closeController(id) }
    }

    /// Give up on every `create` still outstanding on this host.
    ///
    /// `created` carries a terminal id and nothing else -- no request id -- so
    /// the client can only match replies to requests by position. That holds
    /// exactly as long as every request produces exactly one reply, and a
    /// request whose connection died produces none. One stranded entry shifts
    /// the queue by one for the life of the process, which shows up as splits
    /// landing in the tab before last and the window jumping to it.
    ///
    /// Two of the three callers know this for a fact, because they are the
    /// teardown: the connection that would have answered is going. The third
    /// is an assumption -- an `err` on the control session means *one* request
    /// failed, and this abandons the lot because the frame does not say which.
    /// See the `.error` case for why that is the safe direction to be wrong
    /// in.
    private func voidPendingCreates() {
        onCreatesVoided?()
    }

    // MARK: - Starting a server
    //
    // Only for `.local`, and only when there is nothing to connect to. What it
    // runs is `illogicald --ensure`, which makes sure a daemon is listening and
    // exits; the daemon it leaves behind is two forks away in a session of its
    // own and outlives this app. See `LocalDaemon` for why it is that and not a
    // `Process` holding the daemon, an `--stdio` bridge, or a launchd agent.

    /// Whether nothing is listening on a local socket, and this outage has not
    /// already had its one spawn.
    ///
    /// `can`, not `should`: the caller decides whether to spend it. A server
    /// this app started moments ago and which is already refusing connections
    /// is a server worth *not* replacing, and only the caller has the whole of
    /// that question in front of it.
    private func canStartLocalServer(after error: TransportError) -> Bool {
        guard case .local = host, !startedThisOutage else { return false }
        // These two and no others. ECONNREFUSED is a socket file with nothing
        // accepting on it -- a daemon that crashed, or one that never bound.
        // ENOENT is no socket file at all, which is a machine that has never
        // run one. Everything else `UnixSocketTransport` can throw is about
        // *us*: a path too long for `sockaddr_un`, or a descriptor we could not
        // allocate. Starting a daemon fixes neither, and trying to would spend
        // a fork on every reconnect for the life of the process.
        guard case .connectFailed(let code) = error else { return false }
        return code == ECONNREFUSED || code == ENOENT
    }

    private func startLocalServer() {
        guard case .local(let path) = host else { return }
        Trace.log("no server at \(path); starting one")

        startEpoch += 1
        let epoch = startEpoch
        let launcher = self.launcher
        starting = Task { [weak self] in
            do {
                let outcome = try await launcher.ensure(socketPath: path)
                guard let self, self.startEpoch == epoch, !self.closedByUs else { return }
                self.starting = nil
                Trace.log("local server: \(outcome)")
                // Before the connect, so that a daemon which dies during that
                // connect is already inside its probation window.
                self.serverCameUpAt = .now
                // Round again. The connect that failed a moment ago is the
                // connect that succeeds now, and everything after it -- hello,
                // list, the status -- is the path every other host takes.
                self.openControl()
            } catch {
                guard let self, self.startEpoch == epoch, !self.closedByUs else { return }
                self.starting = nil
                let detail = self.describeStartFailure(error, socketPath: path)
                Trace.log("could not start a server at \(path): \(detail)")
                // The same split as a transport failure, and for the same
                // reason: a bundle with no daemon in it will not grow one, and
                // rescanning for it every thirty seconds tells nobody anything.
                if (error as? LocalDaemonError)?.isTransient ?? true {
                    self.scheduleReconnect(detail: detail)
                } else {
                    self.setStatus(.failed(detail))
                }
            }
        }
    }

    private func cancelStart() {
        starting?.cancel()
        starting = nil
        startEpoch += 1
    }

    /// Set `versionSkew` if the daemon answering this socket is not the one the
    /// app shipped.
    ///
    /// Local hosts only. A remote machine's daemon is *expected* to be a
    /// different build -- it was installed from a tarball, on its own schedule,
    /// possibly by somebody else -- and marking every one of them would make
    /// the marker mean nothing.
    ///
    /// Asked of the bundled binary rather than of a version string baked into
    /// the app at build time. One code path, and it is the one that also works
    /// under `ILLOGICAL_DAEMON`: a developer pointing the app at a daemon from
    /// another checkout is exactly the person this notice is for, and a baked
    /// string would compare the wrong two things for them.
    private func compareVersions(_ server: String) {
        guard case .local = host else { return }
        let launcher = self.launcher
        // Inherits this actor, so everything but the launcher call is already
        // where it needs to be. The launcher call is the reason there is a
        // Task at all: it runs `illogicald --version` as a child, and the main
        // actor may not wait for a process.
        Task { [weak self] in
            guard let self else { return }
            if !self.askedForShippedVersion {
                // Before the await, not after. A second `welcome` -- a
                // reconnect, which is ordinary -- arriving during the lookup
                // would otherwise find the flag still false and start a second
                // `illogicald --version` process (REVIEW F13).
                self.askedForShippedVersion = true
                self.shippedVersion = await launcher.bundledVersion()
            }
            guard let shipped = self.shippedVersion else { return }
            self.setVersionSkew(
                shipped == server ? nil : VersionSkew(server: server, shipped: shipped))
        }
    }

    private func setVersionSkew(_ skew: VersionSkew?) {
        guard let skew else {
            versionSkew = nil
            return
        }
        // The version this is about must still be the one on the wire. The
        // lookup above suspends, and a connection replaced while it did would
        // otherwise get a notice about a daemon we are no longer talking to.
        guard serverVersion == skew.server else { return }
        Trace.log(
            "\(host.displayName): server is \(skew.server), this app ships \(skew.shipped)")
        versionSkew = skew
    }

    /// Where a daemon writes what it could not say to anybody.
    ///
    /// `stdio.zig` opens this beside the socket *before* it forks, so it is the
    /// one place a daemon that died during startup left a reason. Naming it is
    /// most of the value of the sentence; everything else the app can say
    /// amounts to "it did not work".
    private static func daemonLogPath(forSocket path: String) -> String {
        (path as NSString).deletingLastPathComponent + "/daemon.log"
    }

    private func describeStartFailure(_ error: Error, socketPath: String) -> String {
        switch error as? LocalDaemonError {
        // Nothing ran, so there is no log to point at, and naming one sends
        // somebody to a file that is not there.
        case .notBundled, .spawn, .none:
            return "\(error)"
        case .failed, .timedOut:
            return "\(error). Its log is \(Self.daemonLogPath(forSocket: socketPath))."
        }
    }

    // MARK: - Reconnecting
    //
    // The same argument as `TerminalController`'s, and the same three lines:
    // a connection that went away is a client that has missed something, and
    // the recovery is to ask again. `list` is idempotent, so there is nothing
    // to merge -- see docs/PROTOCOL.md, "Desync".
    //
    // Over SSH this connection and every terminal's share one TCP connection
    // underneath, so when a network comes back they recover together and only
    // whichever gets there first pays for a handshake.

    private func scheduleReconnect(detail: String?) {
        guard !closedByUs, retry == nil else { return }
        let delay = backoff.next()
        setStatus(.reconnecting(attempt: backoff.attempt, detail: detail))
        Trace.log(
            "\(host.displayName): reconnecting in " + String(format: "%.2fs", delay)
                + " (attempt \(backoff.attempt))")

        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retry = nil
            guard !self.closedByUs else { return }
            self.openControl()
        }
    }

    func refresh() {
        try? control?.send(.list)
    }

    func createTerminal(sessionName: String) {
        try? control?.send(
            .create, json: CreateBody(sessionName: sessionName, cols: 120, rows: 40))
    }

    func kill(_ id: UInt64) {
        try? control?.send(.kill, terminal: id)
        closeController(id)
    }

    /// Why a connection could not be *opened*, phrased for a person.
    ///
    /// This is the throw out of `Connection(host:)` -- ssh not on PATH, a
    /// socket that is not there -- and not ssh's own stderr, which has not been
    /// written yet at this point. That arrives later as
    /// `Connection.failureDescription`, and `controlClosed` is what carries it.
    private func describe(_ error: Error) -> String {
        // The friendly wording is only right for the one failure it describes:
        // a socket nothing is listening on. `connect` is what reports that.
        // A path too long for `sockaddr_un`, or a socket we could not even
        // allocate, is not fixed by starting a daemon, and telling somebody to
        // start one sends them round in a circle -- so those keep the error's
        // own wording, which says what actually happened.
        if case .local(let path) = host, case .connectFailed = error as? TransportError {
            // This used to tell the user to run `illogicald` themselves, which
            // was the gap: the app does that now. Reaching this line means it
            // already tried once this outage and the socket is *still* refusing
            // -- a daemon that started and died in the moment between. The only
            // place with a reason in it is the daemon's own log.
            return "No server at \(path). Its log is \(Self.daemonLogPath(forSocket: path))."
        }
        return "\(error)"
    }

    private func setStatus(_ next: Status) {
        guard status != next else { return }
        status = next
    }

    private func controlClosed(_ connection: Connection) {
        // A connection replaced by a newer one still finishes its stream; only
        // the current one's closing means anything.
        guard control === connection else { return }
        let detail = connection.failureDescription
        control = nil

        // The creates do not survive, though: the connection that would have
        // answered them is the one that just went.
        voidPendingCreates()

        // The session and terminal lists are deliberately *kept*. They are the
        // last thing this machine said it had, the machine is still running
        // them -- that is the entire premise of the project -- and clearing
        // them would take every tab on that host with them through the
        // reconcile, closing panes and their connections over a dropped
        // packet. The next `list` after the reconnect is what corrects them.
        scheduleReconnect(detail: detail)
    }

    /// Takes the connection the frame came in on, for the same reason
    /// `controlClosed` does: a replaced connection's stream is drained to its
    /// end, so a frame buffered on the old one before the swap is delivered
    /// *after* it. Without this guard a stale `session_list` overwrites the
    /// lists the new connection just published and reports `.connected` for a
    /// machine we are in fact still connecting to.
    private func handle(_ frame: Frame, from source: Connection) {
        guard control === source else { return }
        apply(frame)
    }

    /// What a frame does, once it is established that it should do anything.
    /// Split out so `handleForTesting` reaches the real thing rather than a
    /// second copy of it.
    private func apply(_ frame: Frame) {
        // A daemon we have refused gets no further say. `closeControl` below
        // already stops the real connection -- `handle`'s identity guard sends
        // everything home once `control` is nil -- so this is what covers
        // `handleForTesting`, which has no connection to be identified against,
        // and a `created` or `sessions_changed` racing the close.
        guard !protocolRefused else { return }

        switch frame.type {
        case .sessionList:
            guard let list = try? JSONDecoder().decode(SessionListBody.self, from: frame.payload)
            else {
                Trace.log(
                    "bad session list from \(host.displayName): "
                        + (String(data: frame.payload, encoding: .utf8) ?? "<binary>"))
                return
            }
            sessions = list.sessions.map {
                SessionSummary(id: $0.id, name: $0.name, terminals: $0.terminals)
            }
            terminals = list.terminals.map {
                TerminalSummary(
                    id: $0.id,
                    session: $0.session,
                    name: $0.name,
                    command: $0.command,
                    cwd: $0.cwd,
                    cols: $0.cols,
                    rows: $0.rows,
                    residency: Residency(rawValue: $0.residency) ?? .live,
                    attached: $0.attached,
                    ptyReadIdleNanoseconds: $0.ptyReadIdleNanoseconds,
                    exitCode: $0.exitCode)
            }
            // Where the backoff is forgiven, and on the *list* rather than on
            // the connect: a host whose daemon has died accepts a connection
            // and drops it, so resetting on a socket opening would turn the
            // backoff into a tight loop against exactly the machine that needs
            // one. Without this, eight flaky drops left the dropdown stuck at
            // the 30-second ceiling for the life of the process while the
            // panes -- which do reset -- came back in 250ms.
            backoff.reset()
            // And with it the permission to start another server. This frame is
            // the proof that the outage is over, so the *next* one is allowed
            // its own single spawn. Here rather than on the connect, for the
            // same reason the backoff is: a daemon that accepts and drops would
            // otherwise re-arm the spawn on every attempt.
            startedThisOutage = false
            setStatus(.connected)
            onListChanged?()

        case .welcome:
            // On the wire since the first version of the protocol, decoded by
            // `WelcomeBody` since the client existed, and until now read by
            // nobody. It carries the daemon's build, which is the only way to
            // notice that the server answering this socket is not the one this
            // app shipped.
            guard let welcome = try? JSONDecoder().decode(WelcomeBody.self, from: frame.payload)
            else { return }
            serverVersion = welcome.server
            compareVersions(welcome.server)

        case .created:
            guard let created = try? JSONDecoder().decode(CreatedBody.self, from: frame.payload)
            else { return }
            onCreated?(created.terminal)
            refresh()

        case .sessionsChanged:
            refresh()

        case .error:
            // Only the ones addressed to the control session. The daemon
            // answers a bad `kill` or `input` on the terminal's own id, and
            // those say nothing about a `create`.
            //
            // Which control request failed is not knowable -- `hello`, `list`
            // and `create` all carry the control session, and the error names
            // none of them -- so this voids *every* outstanding create rather
            // than guessing at one. Erring the other way silently shifts the
            // split queue for the life of the process; erring this way means a
            // create that did succeed opens a tab of its own instead of a
            // pane, which is visible and recoverable.
            guard frame.terminal == Protocol.controlSession else { break }
            let body = try? JSONDecoder().decode(ErrBody.self, from: frame.payload)
            Trace.log(
                "\(host.displayName): control error: " + (body?.message ?? "unknown"))
            voidPendingCreates()

            // One of them is not merely a failed request. A daemon that
            // refuses `hello` over the protocol version will refuse the next
            // one too: the problem is fixed and unchanging, so retrying it on a
            // timer says nothing. Say it once and stop.
            if body?.code == ProtocolErrorCode.versionMismatch.rawValue {
                protocolRefused = true
                setStatus(
                    .failed(
                        "The server at \(host.displayName) speaks a different protocol version "
                            + "than this app (\(Protocol.version)). Restart it with the "
                            + "illogicald this app shipped."))
                // Nothing scheduled: `scheduleReconnect` is what the backoff
                // runs on, and reaching `.failed` has to mean the retries have
                // stopped. Try Again still works.
                retry?.cancel()
                retry = nil
                cancelStart()
                // And hang up, rather than sit on a connection we have just
                // decided we cannot speak. This is also what drops the
                // `session_list` already queued behind this `err`: `control` is
                // nil afterwards, so both `handle`'s identity guard and
                // `controlClosed`'s discard what is left on this connection
                // rather than scheduling a reconnect against it.
                closeControl()
            }

        default:
            break
        }
    }

    // MARK: - Per-terminal connections

    /// The controller for a terminal on this host, creating and attaching one
    /// if needed.
    func controller(for id: UInt64, cols: UInt16, rows: UInt16) -> TerminalController? {
        if let existing = controllers[id] { return existing }
        guard
            let controller = try? TerminalController(
                terminalID: id, host: host, cols: cols, rows: rows)
        else { return nil }
        controller.connect(cols: cols, rows: rows)
        controllers[id] = controller
        return controller
    }

    func closeController(_ id: UInt64) {
        controllers[id]?.disconnect()
        controllers[id] = nil
    }

    /// The controller for a terminal, if one is open. Read-only, for views:
    /// `controller(for:cols:rows:)` would attach one as a side effect of being
    /// looked at.
    func existingController(_ id: UInt64) -> TerminalController? {
        controllers[id]
    }

    /// Drop controllers for terminals the server no longer lists, so their
    /// reader threads do not linger on a dead socket.
    func pruneControllers() {
        let live = Set(terminals.map(\.id))
        for id in controllers.keys where !live.contains(id) {
            closeController(id)
        }
    }
}
