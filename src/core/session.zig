//! Session and terminal identity.
//!
//! A **session** is a named, long-lived container of **terminals**. A terminal
//! is 1:1 with a PTY and owns the state derived from it. The session is the unit
//! you name, reconnect to and share; the terminal is the unit that has state,
//! parks independently, and gets its own protocol connection.
//!
//!     session "api-work"
//!     |- terminal 1  -> PTY -> zsh
//!     |- terminal 2  -> PTY -> cargo watch
//!     `- terminal 3  -> PTY -> agent
//!
//! Both outlive every client: closing the last client detaches, it never kills.
//! Layout -- which terminal is in which split, tab or window -- is client state
//! and is deliberately absent here. See docs/ARCHITECTURE.md.

const std = @import("std");

/// Identifies a session.
pub const Id = u64;

/// Identifies a terminal within the server. Unique server-wide, not per session,
/// so that a client can attach with a terminal id alone.
pub const TerminalId = u64;

pub const max_name_len = 64;

/// Where a terminal's state currently lives.
pub const Residency = enum {
    /// Terminal state is in memory and being fed by the PTY.
    live,
    /// Idle past the park threshold: state is a snapshot on disk and the
    /// in-memory terminal has been released. The PTY fd has been migrated to
    /// the shared poller; the first byte of PTY *output* unparks it.
    ///
    /// A client attaching to a parked terminal is served from the snapshot on
    /// disk and does not unpark it.
    parked,
    /// Unparking: the snapshot's READY prefix has been decoded, history pages
    /// are still being restored in the background.
    rehydrating,
    /// The child process exited. Terminals in this state are retired on the
    /// next maintenance tick: `exit` closes a terminal, the way it does in
    /// every terminal and multiplexer. Clients learn about it from the
    /// `exited` frame and a `sessions_changed` broadcast.
    exited,
};

/// One terminal: a PTY, its state, and where that state lives.
pub const TerminalSummary = struct {
    id: TerminalId,
    session: Id,
    /// User-visible name. Defaults to the terminal's index, renameable.
    name: []const u8,
    /// Argv[0] of the child, for the client's session dropdown.
    command: []const u8,
    cwd: []const u8,
    cols: u16,
    rows: u16,
    residency: Residency,
    /// Where this terminal's PTY master is being read: `hot` on a dedicated
    /// thread, `polled` in the server's shared poller, `stopped` not at all.
    /// See docs/ARCHITECTURE.md, "Server IO: two regimes per PTY".
    regime: []const u8,
    /// Number of clients currently subscribed to this terminal's output.
    attached: u32,
    /// Monotonic nanoseconds since the PTY last produced output. This — not
    /// general activity — is what drives parking; see `park.shouldPark`.
    pty_read_idle_ns: u64,
    /// Child exit status, when `residency == .exited`.
    exit_code: ?i32 = null,
};

/// A named group of terminals.
pub const Summary = struct {
    id: Id,
    name: []const u8,
    /// Terminals in this session, in user-visible order. Layout is not stored:
    /// the client decides which terminal goes in which split.
    terminals: []const TerminalId,
};

/// Validate a user-supplied session or terminal name.
pub fn validateName(name: []const u8) error{ NameEmpty, NameTooLong, NameInvalidChar }!void {
    if (name.len == 0) return error.NameEmpty;
    if (name.len > max_name_len) return error.NameTooLong;
    for (name) |c| {
        // Names appear in file paths (the park store) and in the CLI, so keep
        // them boring on purpose.
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return error.NameInvalidChar;
    }
}

test "validateName" {
    const testing = std.testing;
    try validateName("build");
    try validateName("agent-07_x.2");
    try testing.expectError(error.NameEmpty, validateName(""));
    try testing.expectError(error.NameInvalidChar, validateName("has space"));
    try testing.expectError(error.NameInvalidChar, validateName("../escape"));
    try testing.expectError(error.NameTooLong, validateName("x" ** (max_name_len + 1)));
}
