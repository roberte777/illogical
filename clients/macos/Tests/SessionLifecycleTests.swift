//  SessionLifecycleTests.swift
//  Renaming and deleting a session, from the window's side.
//
//  Almost everything here runs against a real unix socket that records what it
//  was sent, and that is not ceremony. `Connection.send` on a nil control
//  connection is silently nothing, which is exactly what a correctly refused
//  rename also looks like — so "an invalid name is not sent" passes against a
//  store with the whole gate deleted. It is load-bearing in the other
//  direction too: a delete now only takes the window's tabs if the request
//  actually left, so a store with no socket cannot delete anything at all.
//
//  What is left is driven the way `TabReconcileTests` drives everything: a
//  host publishes its session and terminal lists as plain properties, so
//  setting them and calling `reconcileTabs()` is the same path a `session_list`
//  frame takes.

import AppKit
import Darwin
import IllogicalProtocol
import XCTest

@MainActor
final class SessionLifecycleTests: XCTestCase {
    private static let local = ServerHost.local(socketPath: "/tmp/illogical-lifecycle.sock")

    /// Nothing here reaches the developer's real preferences: `SessionStore`
    /// persists remote hosts, and a unit test has no business writing them.
    private final class InMemoryDefaults: HostDefaults {
        private var values: [String: Data] = [:]
        func data(forKey defaultName: String) -> Data? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) {
            values[defaultName] = value as? Data
        }
    }

    /// A store that dials nothing. The launcher is injected for the same
    /// reason the defaults are: a `.local` host that reached `connect()` with
    /// the real one would start a daemon.
    private func emptyStore(_ hosts: [ServerHost] = [local]) -> SessionStore {
        SessionStore(
            hosts: hosts, defaults: InMemoryDefaults(),
            launcher: RecordingLauncher(.succeedSilently))
    }

    private typealias Listing = (id: UInt64, name: String, terminals: [UInt64])

    /// What a `session_list` frame does, without a socket.
    private func list(_ store: SessionStore, host: ServerHost = local, _ sessions: [Listing]) {
        guard let connection = store.host(host) else { return XCTFail("no such host") }
        connection.sessions = sessions.map {
            SessionSummary(id: $0.id, name: $0.name, terminals: $0.terminals)
        }
        connection.terminals = sessions.flatMap { session in
            session.terminals.map { terminal($0, session: session.id) }
        }
        store.reconcileTabs()
    }

    private func terminal(_ id: UInt64, session: UInt64) -> TerminalSummary {
        TerminalSummary(
            id: id, session: session, name: "t\(id)", command: "/bin/zsh", cwd: "/",
            cols: 80, rows: 24, residency: .live, attached: 0, ptyReadIdleNanoseconds: 0)
    }

    private func ref(_ session: UInt64, on host: ServerHost = local) -> SessionRef {
        SessionRef(host: host, session: session)
    }

    private func tabs(_ store: SessionStore, inSession session: UInt64) -> [TabLayout] {
        store.tabs.filter { $0.session.session == session }
    }

    struct TimedOut: Error, CustomStringConvertible {
        var description: String
    }

    /// The first attempt at anything here is immediate; a couple of seconds is
    /// many times what it needs and still bounded.
    ///
    /// **Throws** on timeout as well as failing. `XCTFail` records a failure
    /// and returns, so a caller that went on to subscript the frames it was
    /// waiting for indexed an empty array — `Fatal error: Index out of range`
    /// killed the whole test process mid-suite, which reports as "12 of 14
    /// tests" rather than as a failure, and skips every `defer` on the way out
    /// so the socket file leaks.
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
        throw TimedOut(description: "timed out waiting for \(description)")
    }

    /// A store whose one host has a live control connection to `server`, past
    /// the handshake — so every frame counted afterwards is one a test asked
    /// for.
    private func connected(_ server: RecordingServer) async throws -> (SessionStore, HostConnection)
    {
        let (store, hosts) = try await connected([server])
        return (store, hosts[0])
    }

    /// The same for several machines at once. Two hosts number their sessions
    /// from 1 independently, which is the whole reason anything here is keyed
    /// by `SessionRef` and not by id.
    private func connected(
        _ servers: [RecordingServer]
    ) async throws -> (SessionStore, [HostConnection]) {
        let addresses = servers.map { ServerHost.local(socketPath: $0.path) }
        let store = SessionStore(
            hosts: addresses, defaults: InMemoryDefaults(),
            launcher: RecordingLauncher(.succeedSilently))
        var connections: [HostConnection] = []
        for address in addresses {
            connections.append(try XCTUnwrap(store.host(address), "no host"))
        }
        for connection in connections { connection.connect() }
        try await waitFor("the handshake") {
            servers.allSatisfy { $0.frames(.list).count == 1 }
        }
        return (store, connections)
    }

    // MARK: - Asking

    /// The dialog has to name what it is about to destroy, and say how much of
    /// it there is: the dropdown row that was right-clicked shows a name and
    /// nothing else, so the terminal count is the part the person cannot see.
    func testRequestingADeleteDescribesWhatWouldGo() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1, 2]), (2, "spare", [3])])

        store.requestDeleteSession(ref(1, on: host.host))

        XCTAssertEqual(
            store.pendingDestruction,
            .deleteSession(ref(1, on: host.host), name: "work", terminalCount: 2))
        let pending = try XCTUnwrap(store.pendingDestruction)
        XCTAssertTrue(pending.title.contains("work"), "the dialog did not name the session")
        XCTAssertTrue(
            pending.message.contains("2 terminals"),
            "the dialog did not say how much was about to close: \(pending.message)")
        // The sentence a destructive dialog is answerable for. Without it this
        // is a question about closing some tabs.
        XCTAssertTrue(
            pending.message.contains("This cannot be undone."),
            "the dialog did not say the delete is irreversible: \(pending.message)")
        XCTAssertEqual(pending.confirmTitle, "Delete Session")

        // Asking destroys nothing. The whole point of W7.
        XCTAssertEqual(store.tabs.count, 3)
        XCTAssertTrue(server.frames(.deleteSession).isEmpty)

        store.cancelPendingDestruction()
        XCTAssertNil(store.pendingDestruction)
        XCTAssertEqual(store.tabs.count, 3, "cancelling deleted the session anyway")
    }

    /// Singular, because "Its 1 terminals will be closed" is the sort of thing
    /// that makes a person distrust the rest of the sentence.
    func testTheDialogCountsInEnglish() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1])])

        store.requestDeleteSession(ref(1, on: host.host))

        let pending = try XCTUnwrap(store.pendingDestruction)
        XCTAssertTrue(pending.message.contains("1 terminal"), pending.message)
        XCTAssertFalse(pending.message.contains("1 terminals"), pending.message)
    }

    /// A session no host lists has no name and no count to describe, and
    /// nothing to delete.
    func testASessionThatIsNotThereRaisesNoDialog() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1])])

        store.requestDeleteSession(ref(99, on: host.host))

        XCTAssertNil(store.pendingDestruction)
    }

    /// The dropdown keeps listing a machine's sessions through a reconnect —
    /// `controlClosed` holds on to them deliberately, because the machine is
    /// still running them — so every row looks exactly as live as it did a
    /// second ago while nothing sent can leave this process. Offering Delete
    /// there asks somebody to confirm something irreversible that cannot
    /// happen.
    func testDeleteIsNotOfferedWhileTheMachineCannotBeReached() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1])])
        XCTAssertTrue(store.canDeleteSession(ref(1, on: host.host)))

        host.disconnect()

        // The session is still listed. That is the trap.
        XCTAssertEqual(host.sessions.count, 1)
        XCTAssertFalse(
            store.canDeleteSession(ref(1, on: host.host)),
            "Delete was offered for a machine nothing can be sent to")
        store.requestDeleteSession(ref(1, on: host.host))
        XCTAssertNil(
            store.pendingDestruction,
            "a dialog promised a delete that could not be sent")
    }

    // MARK: - Confirming

    /// Confirming takes the session's tabs immediately rather than waiting for
    /// the server, because the server is a SIGHUP, a child exit and a
    /// maintenance tick away — and the list it sends in the meantime still
    /// names every one of those terminals. That list must not put the tabs
    /// back.
    func testConfirmingADeleteTakesItsTabsAndTheNextListDoesNotBringThemBack() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1, 2]), (2, "spare", [3])])
        let spare = try XCTUnwrap(store.tabs.first { $0.session.session == 2 })
        store.selectedTabID = try XCTUnwrap(store.tabs.first { $0.session.session == 1 }).id

        store.requestDeleteSession(ref(1, on: host.host))
        store.confirmPendingDestruction()

        XCTAssertNil(store.pendingDestruction)
        XCTAssertEqual(store.tabs.map(\.id), [spare.id])
        // The selection followed, rather than being left pointing at a tab
        // that is no longer there.
        XCTAssertEqual(store.selectedTabID, spare.id)
        XCTAssertEqual(store.selectedSession?.session, 2)

        // The server has not caught up.
        list(store, host: host.host, [(1, "work", [1, 2]), (2, "spare", [3])])
        XCTAssertEqual(
            store.tabs.map(\.id), [spare.id],
            "a list from before the delete landed resurrected the session's tabs")

        // And once it has, nothing changes.
        list(store, host: host.host, [(2, "spare", [3])])
        XCTAssertEqual(store.tabs.map(\.id), [spare.id])
    }

    /// Deleting the only session leaves an empty window rather than a
    /// selection pointing at nothing.
    func testDeletingTheLastSessionLeavesNothingSelected() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1, 2])])

        store.requestDeleteSession(ref(1, on: host.host))
        store.confirmPendingDestruction()

        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.selectedTab)
        XCTAssertNil(store.selectedTabID)
    }

    /// Only the session that was asked about. Two sessions on one host share
    /// every mechanism here — the `closing` set, the tab list, the selection —
    /// so "delete session 1" taking session 2's tabs is a one-character
    /// mistake away.
    func testConfirmingADeleteLeavesEveryOtherSessionAlone() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1, 2]), (2, "spare", [3, 4])])

        store.requestDeleteSession(ref(2, on: host.host))
        store.confirmPendingDestruction()

        XCTAssertEqual(tabs(store, inSession: 2).count, 0)
        XCTAssertEqual(tabs(store, inSession: 1).count, 2)

        // ...and session 1's tabs still track its terminals afterwards, which
        // they would not if its panes had been swept into `closing` too.
        list(store, host: host.host, [(1, "work", [1, 2, 5])])
        XCTAssertEqual(tabs(store, inSession: 1).count, 3)
    }

    /// Every pane, not the first one. Every other test here builds one pane per
    /// tab, where "forget each pane" and "forget `panes[0]`" are the same
    /// program — and a split tab is the ordinary shape of a session somebody
    /// has been working in.
    func testDeletingASessionForgetsEveryPaneOfASplitTab() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1]), (2, "spare", [3])])

        let tab = try XCTUnwrap(store.tabs.first { $0.session.session == 1 })
        let index = try XCTUnwrap(store.tabs.firstIndex { $0.id == tab.id })
        store.tabs[index].root = tab.root.splitting(
            tab.focused, with: Pane(terminal: TerminalRef(host: host.host, terminal: 2)),
            direction: .columns)
        list(store, host: host.host, [(1, "work", [1, 2]), (2, "spare", [3])])
        XCTAssertEqual(store.tabs.first { $0.id == tab.id }?.panes.count, 2)

        store.requestDeleteSession(ref(1, on: host.host))
        store.confirmPendingDestruction()

        XCTAssertEqual(
            store.closing,
            [
                TerminalRef(host: host.host, terminal: 1),
                TerminalRef(host: host.host, terminal: 2),
            ],
            "a pane of the deleted session was left for the reconcile to bring back")

        // Which is what the reconcile then acts on: the server still lists all
        // three, and only the other session's tab may come back.
        list(store, host: host.host, [(1, "work", [1, 2]), (2, "spare", [3])])
        XCTAssertEqual(tabs(store, inSession: 1).count, 0)
        XCTAssertEqual(tabs(store, inSession: 2).count, 1)
    }

    /// The case issue #37 opens with: every terminal killed, and a session
    /// left over with no way to be rid of it. Refusing to delete it — or
    /// telling the person "Its 0 terminals will be closed" — both survive a
    /// suite that only ever deletes sessions with terminals in them.
    func testAnEmptySessionCanBeDeletedAndTheDialogReadsAsASentence() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "leftover", []), (2, "spare", [3])])
        XCTAssertTrue(store.tabs.allSatisfy { $0.session.session == 2 })

        store.requestDeleteSession(ref(1, on: host.host))

        let pending = try XCTUnwrap(
            store.pendingDestruction, "an empty session could not be deleted")
        XCTAssertEqual(pending.message, "It has no terminals left. This cannot be undone.")

        store.confirmPendingDestruction()
        try await waitFor("the delete") { !server.frames(.deleteSession).isEmpty }
        let body = try JSONDecoder().decode(
            DeleteSessionBody.self, from: try XCTUnwrap(server.frames(.deleteSession).first).payload
        )
        XCTAssertEqual(body.session, 1)
        // The other session is untouched, tabs and all.
        XCTAssertEqual(tabs(store, inSession: 2).count, 1)
    }

    /// `confirmPendingDestruction(_:)` is the entry point the dialog uses,
    /// because SwiftUI does not promise whether a button's action or the
    /// dismissal it causes runs first — so the action carries the value it was
    /// presented with. It must work with `pendingDestruction` already cleared.
    func testTheDialogsOwnEntryPointDoesNotDependOnTheSlotStillBeingFull() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1])])
        store.requestDeleteSession(ref(1, on: host.host))
        let pending = try XCTUnwrap(store.pendingDestruction)

        // The dismissal beat the button to it.
        store.cancelPendingDestruction()
        store.confirmPendingDestruction(pending)

        XCTAssertTrue(store.tabs.isEmpty, "the confirmed delete was dropped on the floor")
    }

    /// A confirmed delete that could not be sent must change nothing at all.
    ///
    /// This was a hole with teeth. The teardown ran first and the request went
    /// out through a `try?`, so a delete confirmed while the machine was being
    /// reconnected to dropped the window's tabs, pinned those terminals
    /// invisible for the life of the process — `closing` is only ever
    /// intersected with what is *live*, and they stayed live — and left the
    /// next click on that session making a third terminal, all under a dialog
    /// that had just said "This cannot be undone."
    func testAConfirmedDeleteThatCouldNotBeSentChangesNothing() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1, 2])])
        store.requestDeleteSession(ref(1, on: host.host))
        let pending = try XCTUnwrap(store.pendingDestruction)
        let before = store.tabs.map(\.id)

        // The connection goes between the question and the answer.
        host.disconnect()
        store.confirmPendingDestruction(pending)

        XCTAssertEqual(store.tabs.map(\.id), before, "a delete that never left took the tabs")
        XCTAssertTrue(
            store.closing.isEmpty,
            "terminals were marked closing for a delete the server never heard about")

        // ...and the machine coming back is not a delete either: only asking
        // again is. The count below is what makes the assertions above mean
        // something — one frame, from the second ask, not two.
        host.connect()
        try await waitFor("the reconnect") { host.canSend }
        store.requestDeleteSession(ref(1, on: host.host))
        store.confirmPendingDestruction()

        try await waitFor("the delete") { !server.frames(.deleteSession).isEmpty }
        XCTAssertEqual(server.frames(.deleteSession).count, 1)
        XCTAssertTrue(store.tabs.isEmpty)
    }

    /// The other stale case: the session's last terminal exits between the
    /// right-click and the confirm, so the server has already retired it.
    /// `delete_session` for a session that is gone is answered
    /// `no_such_session` — an `err` on the control channel, which voids every
    /// create in flight on that host.
    func testConfirmingADeleteForASessionThatHasSinceGoneSendsNothing() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1]), (2, "spare", [3])])
        store.requestDeleteSession(ref(1, on: host.host))
        let pending = try XCTUnwrap(store.pendingDestruction)

        // The server retires it while the dialog is up.
        list(store, host: host.host, [(2, "spare", [3])])
        store.confirmPendingDestruction(pending)

        // Barrier: a later, real delete proves the socket was working
        // throughout, so "no frame for session 1" is a fact rather than a
        // race.
        store.requestDeleteSession(ref(2, on: host.host))
        store.confirmPendingDestruction()
        try await waitFor("the second delete") { !server.frames(.deleteSession).isEmpty }

        let sessions = try server.frames(.deleteSession).map {
            try JSONDecoder().decode(DeleteSessionBody.self, from: $0.payload).session
        }
        XCTAssertEqual(sessions, [2], "a delete was sent for a session the server had retired")
    }

    /// The dialog must also take itself down when its subject goes, rather
    /// than sitting there asking about a session that is no longer anywhere.
    func testADialogWhoseSessionGoesAwayDismissesItself() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1]), (2, "spare", [3])])
        store.requestDeleteSession(ref(1, on: host.host))
        XCTAssertNotNil(store.pendingDestruction)

        list(store, host: host.host, [(2, "spare", [3])])

        XCTAssertNil(store.pendingDestruction)
    }

    // MARK: - More than one machine
    //
    // Two machines both number their sessions from 1. Issue #37 asks for this
    // audit by name, and the failure mode of getting it wrong is not a missing
    // tab: it is deleting the wrong machine's session.

    func testDeletingASessionTakesOnlyThatMachinesTabs() async throws {
        let here = try RecordingServer()
        let there = try RecordingServer()
        defer {
            here.stop()
            there.stop()
        }
        let (store, hosts) = try await connected([here, there])
        defer { for host in hosts { host.disconnect() } }
        list(store, host: hosts[0].host, [(3, "work", [1])])
        list(store, host: hosts[1].host, [(3, "build", [1])])
        XCTAssertEqual(store.tabs.count, 2)

        store.requestDeleteSession(ref(3, on: hosts[1].host))
        store.confirmPendingDestruction()

        // Same session id on both machines, and only one of them went.
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs.first?.session.host, hosts[0].host)
        XCTAssertEqual(
            store.closing, [TerminalRef(host: hosts[1].host, terminal: 1)],
            "the wrong machine's terminal was forgotten")
    }

    /// ...and the frame goes to that machine, carrying that machine's id.
    /// Both halves have a plausible wrong answer: sending on `hosts.first`,
    /// and sending `sessions.first?.id` — identity by position.
    func testTheDeleteFrameGoesToTheMachineItIsAbout() async throws {
        let here = try RecordingServer()
        let there = try RecordingServer()
        defer {
            here.stop()
            there.stop()
        }
        let (store, hosts) = try await connected([here, there])
        defer { for host in hosts { host.disconnect() } }
        list(store, host: hosts[0].host, [(1, "work", [1])])
        list(store, host: hosts[1].host, [(4, "build", [1]), (9, "spare", [2])])

        store.requestDeleteSession(ref(9, on: hosts[1].host))
        store.confirmPendingDestruction()

        try await waitFor("the delete") { !there.frames(.deleteSession).isEmpty }
        XCTAssertTrue(
            here.frames(.deleteSession).isEmpty,
            "the delete was sent to the wrong machine")
        let body = try JSONDecoder().decode(
            DeleteSessionBody.self, from: try XCTUnwrap(there.frames(.deleteSession).first).payload)
        XCTAssertEqual(body.session, 9, "the frame carried some other session's id")
    }

    /// The same for rename, and it is the same two mistakes.
    func testTheRenameFrameGoesToTheMachineItIsAbout() async throws {
        let here = try RecordingServer()
        let there = try RecordingServer()
        defer {
            here.stop()
            there.stop()
        }
        let (store, hosts) = try await connected([here, there])
        defer { for host in hosts { host.disconnect() } }
        list(store, host: hosts[0].host, [(1, "work", [1])])
        list(store, host: hosts[1].host, [(4, "build", [1]), (9, "spare", [2])])

        XCTAssertTrue(store.renameSession(ref(9, on: hosts[1].host), to: "released"))

        try await waitFor("the rename") { !there.frames(.renameSession).isEmpty }
        XCTAssertTrue(here.frames(.renameSession).isEmpty, "sent to the wrong machine")
        let body = try JSONDecoder().decode(
            RenameSessionBody.self, from: try XCTUnwrap(there.frames(.renameSession).first).payload)
        XCTAssertEqual(body.session, 9)
        XCTAssertEqual(body.name, "released")
    }

    /// Names are unique per daemon, so a name in use on another machine is not
    /// a reason to refuse. Refusing it would be inventing a rule the server
    /// does not have.
    func testANameUsedOnAnotherMachineDoesNotBlockARename() async throws {
        let here = try RecordingServer()
        let there = try RecordingServer()
        defer {
            here.stop()
            there.stop()
        }
        let (store, hosts) = try await connected([here, there])
        defer { for host in hosts { host.disconnect() } }
        list(store, host: hosts[0].host, [(1, "work", [1])])
        list(store, host: hosts[1].host, [(1, "spare", [1])])

        XCTAssertNil(store.renameRefusal(ref(1, on: hosts[0].host), to: "spare"))
        XCTAssertTrue(store.renameSession(ref(1, on: hosts[0].host), to: "spare"))
        try await waitFor("the rename") { !here.frames(.renameSession).isEmpty }
    }

    // MARK: - Renaming

    /// Issue #37's stability audit — of the *reconcile*, which is what this
    /// drives: no rename request is sent here, only the `session_list` that a
    /// completed one produces. A session id is stable across a rename, so
    /// everything holding a session must key on the id; `TabLayout.session` is
    /// a `SessionRef`, which does. If it keyed on the name, this list would
    /// empty the tab strip and move the selection.
    func testANewNameOnTheSameSessionIdMovesNoTabAndNoSelection() {
        let store = emptyStore()
        list(store, [(1, "work", [1, 2])])
        let ids = store.tabs.map(\.id)
        guard ids.count == 2 else { return XCTFail("expected two tabs, got \(ids.count)") }
        store.selectedTabID = ids[1]

        // What a rename actually delivers to a client: `sessions_changed`, and
        // then a `list` carrying the same session id under a new name.
        list(store, [(1, "done", [1, 2])])

        XCTAssertEqual(store.tabs.map(\.id), ids, "a rename rebuilt the tabs")
        XCTAssertEqual(store.selectedTabID, ids[1], "a rename moved the selection")
        XCTAssertEqual(store.visibleTabs.count, 2, "the strip lost its tabs to a rename")
        // ...and the new name really is what the window now reads, so the
        // three assertions above are about a name that changed rather than one
        // that never did.
        XCTAssertEqual(store.selectedSession?.session, 1)
        XCTAssertEqual(store.selectedSessionSummary?.name, "done")
    }

    /// You rename *towards* names you already use, so this is the likelier
    /// collision of the two. The server answers `name_in_use`, and that `err`
    /// on the control channel voids every create outstanding on the host — so
    /// an unchecked rename does not merely fail quietly, it turns somebody's
    /// in-flight ⌘D into a whole new tab that steals the selection.
    func testRenamingToANameThatMachineAlreadyUsesIsRefusedBeforeItIsSent() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1]), (2, "spare", [2])])

        XCTAssertEqual(store.renameRefusal(ref(1, on: host.host), to: "spare"), .inUse)
        XCTAssertFalse(store.renameSession(ref(1, on: host.host), to: "spare"))

        // A session keeping its own name is not a collision: the server treats
        // that as a no-op success.
        XCTAssertNil(store.renameRefusal(ref(1, on: host.host), to: "work"))

        // Barrier: an accepted rename after the refused one proves the refused
        // one had its chance.
        XCTAssertTrue(store.renameSession(ref(1, on: host.host), to: "done"))
        try await waitFor("the accepted rename") { !server.frames(.renameSession).isEmpty }
        let names = try server.frames(.renameSession).map {
            try JSONDecoder().decode(RenameSessionBody.self, from: $0.payload).name
        }
        XCTAssertEqual(names, ["done"], "a name already in use was put on the wire")
    }

    /// The field said one thing and Enter did another: the colour and the
    /// tooltip were computed from the raw text and the commit sent a trimmed
    /// one, so `work ` painted amber, offered the "use these characters"
    /// advice, and then renamed successfully.
    func testTrailingSpaceIsTrimmedRatherThanRefused() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "work", [1])])

        XCTAssertNil(
            store.renameRefusal(ref(1, on: host.host), to: " done "),
            "the field was told to refuse a name the commit accepts")
        XCTAssertTrue(store.renameSession(ref(1, on: host.host), to: " done "))

        try await waitFor("the rename") { !server.frames(.renameSession).isEmpty }
        let body = try JSONDecoder().decode(
            RenameSessionBody.self, from: try XCTUnwrap(server.frames(.renameSession).first).payload
        )
        XCTAssertEqual(body.name, "done", "the untrimmed name went to a server that refuses it")

        // An *inner* space is a real character in a name the server will not
        // take, and is still refused: trimming must not become "delete the
        // spaces".
        XCTAssertEqual(store.renameRefusal(ref(1, on: host.host), to: "my project"), .badCharacters)
    }

    // MARK: - What the dropdown offers

    /// `filterOffer` is the dropdown's whole policy for its free-text field:
    /// whether Enter creates, and what is shown when it does not. It lives in
    /// the store because those two must agree — a Create row whose Enter does
    /// nothing is exactly the silent no-op the notice was added to kill — and
    /// because a SwiftUI view cannot be asked either question.
    func testTheFilterOffersCreateOnlyForNamesTheServerWouldTake() {
        let store = emptyStore()
        list(store, [(1, "work", [1])])

        XCTAssertEqual(store.filterOffer(""), .nothing, "an empty field is not a mistake")
        XCTAssertEqual(store.filterOffer("   "), .nothing)
        // A name that is already a row: switch to it rather than making a
        // second one.
        XCTAssertEqual(store.filterOffer("work"), .nothing)
        XCTAssertEqual(store.filterOffer("WORK"), .nothing)

        XCTAssertEqual(store.filterOffer("fresh"), .create("fresh"))
        // The offer carries the name that will actually be sent, so the row
        // shown and the create issued cannot be two different strings.
        XCTAssertEqual(store.filterOffer("  fresh  "), .create("fresh"))

        XCTAssertEqual(store.filterOffer("My Project"), .refused(.badCharacters))
        XCTAssertEqual(store.filterOffer("../escape"), .refused(.badCharacters))
        XCTAssertEqual(
            store.filterOffer(String(repeating: "x", count: SessionName.maxLength + 1)),
            .refused(.tooLong))
    }

    /// The rule is the server's; the sentences are this app's. They are the
    /// point: before them, a space in the field produced no Create row, no
    /// match to fall through to, and no reason on screen.
    func testTheNamingRuleSaysWhyRatherThanOnlyNo() {
        XCTAssertNil(SessionNameRefusal.of("build"))
        XCTAssertNil(SessionNameRefusal.of("agent-07_x.2"))
        XCTAssertNil(SessionNameRefusal.of(String(repeating: "x", count: SessionName.maxLength)))

        XCTAssertEqual(SessionNameRefusal.of(""), .empty)
        XCTAssertEqual(SessionNameRefusal.of("has space"), .badCharacters)
        XCTAssertEqual(SessionNameRefusal.of("../escape"), .badCharacters)
        XCTAssertEqual(
            SessionNameRefusal.of(String(repeating: "x", count: SessionName.maxLength + 1)),
            .tooLong)

        // Every refusal has something to say, and no two say the same thing.
        let refusals: [SessionNameRefusal] = [.empty, .tooLong, .badCharacters, .inUse]
        let messages = refusals.map(\.message)
        XCTAssertEqual(Set(messages).count, refusals.count, "two refusals give the same reason")
        XCTAssertFalse(messages.contains { $0.isEmpty }, "a refusal with nothing to say")
    }

    /// A sentence that does not fit is worse than a shorter one: the dropdown
    /// is a fixed 172pt and SwiftUI truncates in the middle of the line, so
    /// "Letters, digits, . _ - only" drew as "…, . _ -…" — losing the half
    /// that carried the meaning, in the message people hit by typing a space.
    ///
    /// Measured against the geometry the row is actually built from rather
    /// than a number copied into the test, so moving `MenuMetrics` moves this.
    func testEveryRefusalFitsTheRowItIsDrawnIn() {
        let font = NSFont.systemFont(ofSize: MenuMetrics.font)
        let refusals: [SessionNameRefusal] = [.empty, .tooLong, .badCharacters, .inUse]
        for refusal in refusals {
            let width = (refusal.message as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(
                width, MenuMetrics.titleWidth,
                "“\(refusal.message)” is \(width)pt in a \(MenuMetrics.titleWidth)pt row")
        }
    }

    // MARK: - What actually goes on the wire

    /// The session id rides in the body because the header's u64 addresses a
    /// *terminal*; the frame goes out on the control channel. Both halves of
    /// that are the protocol's, and getting either wrong is a rename that
    /// lands on nothing.
    func testARenameGoesOutOnTheControlChannelWithTheSessionInItsBody() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(7, "work", [1])])

        XCTAssertTrue(store.renameSession(ref(7, on: host.host), to: "done"))

        try await waitFor("the rename") { !server.frames(.renameSession).isEmpty }
        let frame = try XCTUnwrap(server.frames(.renameSession).first)
        XCTAssertEqual(frame.terminal, Protocol.controlSession)
        let body = try JSONDecoder().decode(RenameSessionBody.self, from: frame.payload)
        XCTAssertEqual(body.session, 7)
        XCTAssertEqual(body.name, "done")
    }

    /// A name the server would refuse must not reach it. Not for politeness:
    /// the refusal is an `err` on the control channel, and `HostConnection`
    /// answers one of those by voiding *every* create outstanding on the host
    /// — the frame does not say which request failed. So a typo in a rename
    /// field turns an unrelated ⌘D split into a tab.
    func testANameTheServerWouldRefuseIsNeverSent() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(7, "work", [1])])

        XCTAssertFalse(store.renameSession(ref(7, on: host.host), to: "bad name"))
        // A barrier, and worth being exact about what it proves: frames leave
        // in order — `Connection.send` writes a whole frame under one lock
        // before it returns — and this socket reads them in order. So a
        // `rename_session` that has arrived means everything sent before it
        // has arrived too, and the refused name was not sent *earlier*. It is
        // not a proof that nothing could ever send it later.
        XCTAssertTrue(store.renameSession(ref(7, on: host.host), to: "fine"))

        try await waitFor("the second rename") { !server.frames(.renameSession).isEmpty }
        let names = try server.frames(.renameSession).map {
            try JSONDecoder().decode(RenameSessionBody.self, from: $0.payload).name
        }
        // The names, not the count: if the refused one went out this says so,
        // where a bare count would only say "two", and would say it wrongly
        // for a moment whenever the reader thread is behind.
        XCTAssertEqual(names, ["fine"], "a name the server refuses was put on the wire")
    }

    /// The same gate on the other path that carries free text: the dropdown's
    /// "Filter or create…" field, which reaches `createTerminal(sessionName:)`
    /// with whatever was typed.
    func testAFreeTextSessionNameIsCheckedBeforeACreateIsSent() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }

        store.createTerminal(sessionName: "My Project")
        store.createTerminal(sessionName: " my-project ")

        try await waitFor("the create") { !server.frames(.create).isEmpty }
        let names = try server.frames(.create).map {
            try JSONDecoder().decode(CreateBody.self, from: $0.payload).sessionName
        }
        XCTAssertEqual(
            names, ["my-project"],
            "a create the daemon answers with err(invalid_name) went out, and an err "
                + "voids every create in flight on this host")
    }

    /// ⌘T, the `+` button and the empty-state button, which pass no name at
    /// all — untested anywhere until now, so gating them off entirely was
    /// invisible.
    ///
    /// And the name they derive came *from the server*, so it is not this
    /// app's to refuse. This app talks to daemons it did not ship, and one
    /// older than the naming rule may be holding a session called `my project`
    /// — checking it here would make all three buttons do nothing, with
    /// nothing on screen saying why: the silent no-op the gate exists to
    /// prevent, turned on the user.
    func testTheDefaultCreateJoinsTheFrontSessionWhateverItIsCalled() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "my project", [1])])

        store.createTerminal()

        try await waitFor("the create") { !server.frames(.create).isEmpty }
        let body = try JSONDecoder().decode(
            CreateBody.self, from: try XCTUnwrap(server.frames(.create).first).payload)
        XCTAssertEqual(body.sessionName, "my project")
    }

    /// A split is the other path that reaches `create`, and it used to call
    /// the host directly — the one create in the app with no gate at all and
    /// nowhere to grow one. It joins the tab's *own* session, which is the
    /// half a shared helper has to keep right.
    func testASplitJoinsItsOwnTabsSession() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(1, "first", [1]), (2, "second", [2])])

        let tab = try XCTUnwrap(store.tabs.first { $0.session.session == 2 })
        store.split(pane: tab.focused, in: tab.id, direction: .columns)

        try await waitFor("the create") { !server.frames(.create).isEmpty }
        let body = try JSONDecoder().decode(
            CreateBody.self, from: try XCTUnwrap(server.frames(.create).first).payload)
        XCTAssertEqual(
            body.sessionName, "second",
            "the split was spliced into a different session's tab")
    }

    /// The app always cascades: it has already asked. `only_if_empty` is for
    /// scripts, and the key it is spelled with is the one the daemon parses.
    func testConfirmingADeleteSendsDeleteSessionThatCascades() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(7, "work", [1, 2])])

        store.requestDeleteSession(ref(7, on: host.host))
        store.confirmPendingDestruction()

        try await waitFor("the delete") { !server.frames(.deleteSession).isEmpty }
        let frame = try XCTUnwrap(server.frames(.deleteSession).first)
        XCTAssertEqual(frame.terminal, Protocol.controlSession)
        let body = try JSONDecoder().decode(DeleteSessionBody.self, from: frame.payload)
        XCTAssertEqual(body.session, 7)
        XCTAssertFalse(body.onlyIfEmpty)
        let json = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
        XCTAssertEqual(json?["only_if_empty"] as? Bool, false, "the daemon parses this key")

        // And no `kill` beside it. The server's own cascade ends every
        // terminal in the session, so a kill per terminal from here would be a
        // second SIGHUP for each of them. The delete having arrived is the
        // barrier: a kill would have gone out ahead of it.
        XCTAssertTrue(
            server.frames(.kill).isEmpty,
            "a session delete signalled every terminal twice")
    }

    /// A pane's connection is not something the reconcile cleans up in time:
    /// `pruneControllers` runs off the next list, and the terminals are still
    /// on that list for as long as it takes their children to go. Closing them
    /// here is what stops a deleted session's readers sitting on dead sockets.
    func testConfirmingADeleteClosesTheConnectionsToItsTerminals() async throws {
        let server = try RecordingServer()
        defer { server.stop() }
        let (store, host) = try await connected(server)
        defer { host.disconnect() }
        list(store, host: host.host, [(7, "work", [1, 2]), (8, "spare", [3])])

        XCTAssertNotNil(host.controller(for: 1, size: .test(cols: 80, rows: 24)))
        XCTAssertNotNil(host.controller(for: 3, size: .test(cols: 80, rows: 24)))

        store.requestDeleteSession(ref(7, on: host.host))
        store.confirmPendingDestruction()

        XCTAssertNil(
            host.existingController(1),
            "a pane's connection outlived the session it was in")
        XCTAssertNotNil(
            host.existingController(3),
            "deleting one session closed another session's connection")
    }

    // MARK: - Reaching the rename field from the menu bar

    /// File ▸ Rename Session… has no field to reach — `SessionMenu` only
    /// exists while the dropdown is open — so it leaves the session on the
    /// store and opens the menu.
    func testTheMenuBarArmsTheRenameFieldAndOpensTheDropdown() {
        let store = emptyStore()
        list(store, [(1, "work", [1])])
        store.sessionMenuOpen = false

        store.requestRenameSession(ref(1))

        XCTAssertEqual(store.pendingRename, ref(1))
        XCTAssertTrue(store.sessionMenuOpen, "the field was armed in a menu nothing opened")

        // Nothing is armed for a session that is not there: the dropdown would
        // find no row matching it, focus nothing, and sit there with a dead
        // keyboard.
        store.pendingRename = nil
        store.requestRenameSession(ref(99))
        XCTAssertNil(store.pendingRename)
    }
}

/// A unix socket that accepts clients, holds them, and remembers every frame it
/// was sent.
///
/// `HangUpServer` cannot stand in: it reads exactly two frames and then closes
/// the connection, and everything above is about the *third* — a
/// `rename_session` or a `delete_session` issued long after the handshake.
///
/// Deliberately not `@MainActor`, like `HangUpServer` and for the same reason:
/// its accept and read loops run on threads of their own, and a
/// main-actor-isolated method called from one of those trips the executor
/// assertion and takes the test runner down with it.
final class RecordingServer: @unchecked Sendable {
    struct Received: Sendable {
        var type: FrameType
        /// The header's u64. Named as the protocol means it: a terminal id,
        /// with zero for the control channel.
        var terminal: UInt64
        var payload: Data
    }

    let path: String
    private let listener: Int32
    private let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [Received] = []
        private var _clients: [Int32] = []
        private var _stopped = false

        var frames: [Received] {
            lock.lock()
            defer { lock.unlock() }
            return _frames
        }

        var stopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _stopped
        }

        func record(_ frame: Received) {
            lock.lock()
            defer { lock.unlock() }
            _frames.append(frame)
        }

        /// Keep a client descriptor for the life of the server, or refuse it
        /// when the server has already stopped — otherwise a connection
        /// accepted during teardown leaks into the rest of the suite.
        func hold(_ fd: Int32) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if _stopped { return false }
            _clients.append(fd)
            return true
        }

        func stop() -> [Int32] {
            lock.lock()
            defer { lock.unlock() }
            _stopped = true
            let clients = _clients
            _clients = []
            return clients
        }
    }

    /// Everything it has been sent, oldest first, across every connection.
    var frames: [Received] { state.frames }

    func frames(_ type: FrameType) -> [Received] { state.frames.filter { $0.type == type } }

    init() throws {
        path = "/tmp/illogical-record-\(getpid())-\(UInt32.random(in: 0..<1_000_000)).sock"
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
        let thread = Thread { RecordingServer.accept(fd, state) }
        thread.name = "illogical.test.record"
        thread.start()
    }

    /// A reader per client. The app opens one connection for control and one
    /// more per pane, and a single-threaded loop would record the control
    /// connection's frames only until a pane connected.
    private static func accept(_ listener: Int32, _ state: State) {
        while !state.stopped {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 { return }
            guard state.hold(client) else {
                Darwin.close(client)
                return
            }
            let thread = Thread { RecordingServer.read(client, state) }
            thread.name = "illogical.test.record.client"
            thread.start()
        }
    }

    private static func read(_ fd: Int32, _ state: State) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending: [UInt8] = []
        while !state.stopped {
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
            state.record(
                Received(
                    type: header.type, terminal: header.session,
                    payload: Data(pending[Protocol.headerLength..<total])))
            pending.removeFirst(total)
        }
    }

    func stop() {
        for client in state.stop() {
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(path)
    }
}
