//  SessionStore.swift
//  Connection state for one or more hosts.
//
//  SCAFFOLD: the summaries below are placeholders so the shell is navigable.
//  M2 replaces `connect()` with a real transport (unix socket locally, an
//  `ssh <host> illogicald --stdio` pipe remotely) speaking IllogicalProtocol.

import Foundation
import IllogicalProtocol
import Observation

@Observable
@MainActor
final class SessionStore {
    var host: ServerHost = .local(socketPath: SessionStore.defaultSocketPath)
    var sessions: [SessionSummary] = []
    var selectedID: SessionSummary.ID?

    var selected: SessionSummary? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    static var defaultSocketPath: String {
        let state =
            ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/state").path
        return state + "/illogical/server.sock"
    }

    func connect() {
        // TODO(M2): open the transport, send `hello`, populate from `welcome`.
        sessions = SessionStore.placeholders
        selectedID = sessions.first?.id
    }

    func attach(_ id: SessionSummary.ID) {
        // TODO(M2): send `attach`, then drive SnapshotRestore from the
        // snapshot_chunk frames while applying `output` frames live.
        selectedID = id
    }

    private static let placeholders: [SessionSummary] = [
        .init(
            id: 1, name: "shell", command: "zsh", cwd: "~", cols: 120, rows: 40,
            residency: .live, attached: 1, idleNanoseconds: 0
        ),
        .init(
            id: 2, name: "build", command: "zig", cwd: "~/coding/illogical",
            cols: 120, rows: 40, residency: .parked, attached: 0,
            idleNanoseconds: 5 * 60 * 1_000_000_000
        ),
    ]
}
