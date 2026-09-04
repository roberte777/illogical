//! Session identity and metadata.
//!
//! A session is a long-lived PTY plus the terminal state derived from it. It
//! outlives every client: closing the last client detaches, it never kills.

const std = @import("std");

pub const Id = u64;

pub const max_name_len = 64;

/// Where a session's terminal state currently lives.
pub const Residency = enum {
    /// Terminal state is in memory and being fed by the PTY.
    live,
    /// Idle past the park threshold: state is a snapshot on disk and the
    /// in-memory terminal has been released. The PTY fd is still registered
    /// with the event loop so the first byte of output unparks it.
    parked,
    /// Unparking: the snapshot's READY prefix has been decoded, history pages
    /// are still being restored in the background.
    rehydrating,
    /// The child process exited. Kept until the user dismisses it so the
    /// final screen is still readable.
    exited,
};

pub const Summary = struct {
    id: Id,
    /// User-visible name. Defaults to the session's index, renameable.
    name: []const u8,
    /// Argv[0] of the child, for the client's session dropdown.
    command: []const u8,
    cwd: []const u8,
    cols: u16,
    rows: u16,
    residency: Residency,
    /// Number of clients currently subscribed to this session's output.
    attached: u32,
    /// Monotonic nanoseconds since the PTY last produced output.
    idle_ns: u64,
    /// Child exit status, when `residency == .exited`.
    exit_code: ?i32 = null,
};

/// Validate a user-supplied session name.
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
