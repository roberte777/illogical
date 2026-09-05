//  Session.swift
//  Client-side view of sessions and terminals. Mirrors src/core/session.zig.
//
//  A session is a named container of terminals; a terminal is 1:1 with a PTY and
//  holds the state. Each terminal gets its own protocol connection, so a window
//  showing four splits holds four connections. Layout is local UI state and is
//  deliberately not part of this model.

import Foundation

public enum Residency: String, Codable, Sendable {
    case live
    case parked
    case rehydrating
    case exited
}

/// One terminal: a PTY, its state, and where that state lives.
public struct TerminalSummary: Identifiable, Equatable, Codable, Sendable {
    public var id: UInt64
    public var session: UInt64
    public var name: String
    public var command: String
    public var cwd: String
    public var cols: UInt16
    public var rows: UInt16
    public var residency: Residency
    public var attached: UInt32
    /// Time since the PTY last produced *output*. This, not general activity,
    /// is what drives parking — a terminal being typed into that produces
    /// nothing is still idle.
    public var ptyReadIdleNanoseconds: UInt64
    public var exitCode: Int32?

    public init(
        id: UInt64,
        session: UInt64,
        name: String,
        command: String,
        cwd: String,
        cols: UInt16,
        rows: UInt16,
        residency: Residency,
        attached: UInt32,
        ptyReadIdleNanoseconds: UInt64,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.session = session
        self.name = name
        self.command = command
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.residency = residency
        self.attached = attached
        self.ptyReadIdleNanoseconds = ptyReadIdleNanoseconds
        self.exitCode = exitCode
    }
}

/// A named group of terminals.
public struct SessionSummary: Identifiable, Equatable, Codable, Sendable {
    public var id: UInt64
    public var name: String
    /// Terminals in user-visible order. Which terminal sits in which split is
    /// client state and is not carried here.
    public var terminals: [UInt64]

    public init(id: UInt64, name: String, terminals: [UInt64]) {
        self.id = id
        self.name = name
        self.terminals = terminals
    }
}

/// Where a client connects. Local is a unix socket; remote is the same
/// protocol tunnelled over `ssh <host> illogicald --stdio`.
public enum ServerHost: Hashable, Sendable {
    case local(socketPath: String)
    case ssh(destination: String, remoteBinary: String = "illogicald")

    public var displayName: String {
        switch self {
        case .local: "Local"
        case .ssh(let destination, _): destination
        }
    }
}
