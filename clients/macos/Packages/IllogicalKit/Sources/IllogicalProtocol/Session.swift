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

/// The naming rule, client-side. Mirrors `session.validateName` in
/// src/core/session.zig.
///
/// The server is the authority — it checks the session name on every `create`
/// and every `rename_session`, and answers ``ProtocolErrorCode/invalidName`` —
/// which is exactly what makes checking here load-bearing rather than
/// cosmetic. A refused `create` produces no `created` frame at all, so a
/// free-text session field that sends an invalid name silently does nothing; a
/// refused rename reverts on the next list. Anything offering either must gate
/// on this first. Both implementations carry the same cases in their tests.
///
/// The rule covers *session* names only. A terminal's name never reaches disk
/// and is not validated by either side.
public enum SessionName {
    /// Mirrors `session.max_name_len`.
    public static let maxLength = 64

    /// One to ``maxLength`` bytes of `[A-Za-z0-9._-]`.
    ///
    /// Byte count, not character count: the server measures a `[]const u8` and
    /// refuses anything outside ASCII anyway, so a name that passes here is a
    /// name whose UTF-8 length is its character count.
    public static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= maxLength else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): true
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): true
            case UInt8(ascii: "a")...UInt8(ascii: "z"): true
            case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."): true
            default: false
            }
        }
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
///
/// `Codable` because the window remembers which remote hosts you added. The
/// local one is never stored: it is wherever this machine puts its socket.
public enum ServerHost: Hashable, Sendable, Codable {
    case local(socketPath: String)
    case ssh(destination: String, remoteBinary: String = "illogicald")

    // Hand-written rather than synthesized, for one reason: the synthesized
    // `init(from:)` uses `decode(_:forKey:)`, which does *not* honour the
    // `= "illogicald"` default above. A stored blob without that key threw
    // `keyNotFound` — and because the whole array is decoded in one `try?`,
    // one such entry silently forgot every remembered host, not one field.

    private enum CodingKeys: String, CodingKey { case local, ssh }
    private enum LocalKeys: String, CodingKey { case socketPath }
    private enum SSHKeys: String, CodingKey { case destination, remoteBinary }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.local) {
            let nested = try container.nestedContainer(keyedBy: LocalKeys.self, forKey: .local)
            self = .local(socketPath: try nested.decode(String.self, forKey: .socketPath))
            return
        }
        let nested = try container.nestedContainer(keyedBy: SSHKeys.self, forKey: .ssh)
        self = .ssh(
            destination: try nested.decode(String.self, forKey: .destination),
            // The one line this whole override exists for.
            remoteBinary: try nested.decodeIfPresent(String.self, forKey: .remoteBinary)
                ?? "illogicald")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let socketPath):
            var nested = container.nestedContainer(keyedBy: LocalKeys.self, forKey: .local)
            try nested.encode(socketPath, forKey: .socketPath)
        case .ssh(let destination, let remoteBinary):
            var nested = container.nestedContainer(keyedBy: SSHKeys.self, forKey: .ssh)
            try nested.encode(destination, forKey: .destination)
            try nested.encode(remoteBinary, forKey: .remoteBinary)
        }
    }

    public var displayName: String {
        switch self {
        case .local: "Local"
        case .ssh(let destination, _): destination
        }
    }

    public var isRemote: Bool {
        if case .ssh = self { return true }
        return false
    }

    /// The `ssh` this host would run. Nil for a local one.
    public var sshOptions: SSHCommand.Options? {
        guard case .ssh(let destination, let remoteBinary) = self else { return nil }
        return SSHCommand.Options(
            destination: destination,
            remoteBinary: remoteBinary,
            // For a second OpenSSH, and so a test can stand something else in
            // its place. The same variable the Zig CLI reads.
            ssh: ProcessInfo.processInfo.environment["ILLOGICAL_SSH"] ?? "ssh")
    }

    /// Open a transport to this host.
    ///
    /// The only place in the client with an opinion about local versus remote.
    /// Everything above it sees frames and cannot tell the difference — which
    /// is what makes "the dropdown lists terminals on other machines" a change
    /// to the session store rather than to the terminal.
    public func makeTransport() throws -> Transport {
        switch self {
        case .local(let path):
            return try UnixSocketTransport(path: path)
        case .ssh:
            guard let options = sshOptions else {
                preconditionFailure("an ssh host always has ssh options")
            }
            SSHCommand.prepareControlDirectory(options)
            return try CommandTransport(argv: SSHCommand.argv(options))
        }
    }
}
