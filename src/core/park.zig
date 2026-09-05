//! Parking and rehydration.
//!
//! A session that produces no output for `default_park_after` is *parked*: its
//! terminal state is encoded with `ghostty_snapshot_encode` and written to the
//! park store, then the in-memory terminal is freed. The PTY file descriptor
//! stays registered with the event loop, so the very next byte of output wakes
//! the session back up.
//!
//! Rehydration is two-phase, mirroring the snapshot format's READY marker:
//!
//!   1. `ghostty_snapshot_decoder_ready` restores the active screen and any
//!      unfinished VT parser input. This is the sub-millisecond path and is all
//!      that is needed before PTY bytes can be applied again.
//!   2. `ghostty_snapshot_decoder_next` prepends history pages, newest first,
//!      off the critical path. Live output may be written to the terminal
//!      between calls.
//!
//! The same two phases are what an attaching client sees over the wire, which
//! is why the on-disk park file and the `snapshot_chunk` payload are the same
//! bytes. See docs/PARKING.md.

const std = @import("std");
const session = @import("session.zig");

/// Idle time after which a live session is parked.
pub const default_park_after_ns: u64 = 60 * std.time.ns_per_s;

pub const Config = struct {
    park_after_ns: u64 = default_park_after_ns,
    /// Park even while clients are attached. Attached-but-silent sessions are
    /// the common case for agent workloads, so this defaults on.
    park_while_attached: bool = true,
    /// Refuse to park a terminal whose snapshot would exceed this. Such a
    /// session stays resident and is reported in `illogical doctor`.
    max_snapshot_bytes: u64 = 256 << 20,
};

/// Filesystem layout of the park store.
///
///     $XDG_STATE_HOME/illogical/            (or ~/.local/state/illogical)
///       server.sock                          control socket
///       server.pid
///       sessions/<id>/meta.json              survives restarts
///       sessions/<id>/snapshot.gsnp          GHOSTSNP stream
///       sessions/<id>/snapshot.gsnp.tmp      staged write, renamed on fsync
pub const Store = struct {
    root: []const u8,

    pub const snapshot_basename = "snapshot.gsnp";
    pub const meta_basename = "meta.json";

    pub fn sessionDir(
        self: Store,
        buf: []u8,
        id: session.Id,
    ) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/sessions/{d}", .{ self.root, id });
    }

    pub fn snapshotPath(
        self: Store,
        buf: []u8,
        id: session.Id,
    ) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(
            buf,
            "{s}/sessions/{d}/{s}",
            .{ self.root, id, snapshot_basename },
        );
    }
};

/// Should this session be parked right now?
pub fn shouldPark(
    cfg: Config,
    residency: session.Residency,
    idle_ns: u64,
    attached: u32,
) bool {
    if (residency != .live) return false;
    if (attached > 0 and !cfg.park_while_attached) return false;
    return idle_ns >= cfg.park_after_ns;
}

test "shouldPark honours residency, idle time and attachment" {
    const testing = std.testing;
    const cfg: Config = .{};
    const idle = default_park_after_ns;

    try testing.expect(shouldPark(cfg, .live, idle, 0));
    try testing.expect(shouldPark(cfg, .live, idle, 3));
    try testing.expect(!shouldPark(cfg, .live, idle - 1, 0));
    try testing.expect(!shouldPark(cfg, .parked, idle, 0));
    try testing.expect(!shouldPark(cfg, .exited, idle, 0));

    const keep: Config = .{ .park_while_attached = false };
    try testing.expect(!shouldPark(keep, .live, idle, 1));
    try testing.expect(shouldPark(keep, .live, idle, 0));
}

test "store paths" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const store: Store = .{ .root = "/state/illogical" };
    try testing.expectEqualStrings(
        "/state/illogical/sessions/7/snapshot.gsnp",
        try store.snapshotPath(&buf, 7),
    );
}
