//  Session.swift
//  Client-side view of a server session. Mirrors src/core/session.zig.

import Foundation

public enum Residency: String, Codable, Sendable {
    case live
    case parked
    case rehydrating
    case exited
}

public struct SessionSummary: Identifiable, Equatable, Codable, Sendable {
    public var id: UInt64
    public var name: String
    public var command: String
    public var cwd: String
    public var cols: UInt16
    public var rows: UInt16
    public var residency: Residency
    public var attached: UInt32
    public var idleNanoseconds: UInt64
    public var exitCode: Int32?

    public init(
        id: UInt64,
        name: String,
        command: String,
        cwd: String,
        cols: UInt16,
        rows: UInt16,
        residency: Residency,
        attached: UInt32,
        idleNanoseconds: UInt64,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.residency = residency
        self.attached = attached
        self.idleNanoseconds = idleNanoseconds
        self.exitCode = exitCode
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
