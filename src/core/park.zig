//! Parking and rehydration.
//!
//! There are *three* independent levels of parking. This module currently models
//! level 1; the others are listed here so the vocabulary matches docs/PARKING.md.
//!
//!   1. **Terminal parking.** A terminal whose PTY produces no *reads* for
//!      `park_after_ns` is snapshotted to disk with `ghostty_snapshot_encode`
//!      and its in-memory terminal freed.
//!   2. **PTY parking.** A hot PTY owns a dedicated OS thread blocked on
//!      `read()`; that is measurably the fastest way to move bytes. When the
//!      terminal is parked or nobody is watching it, the fd migrates to a single
//!      shared kqueue/epoll poller — ~5-10% throughput for a large drop in
//!      per-fd cost. See `src/daemon` (M4).
//!   3. **Client buffer parking.** Per-client pipeline buffers are freed once a
//!      client has been idle past its initial sync.
//!
//! Note that "idle" means **no PTY reads**, not "no activity". Keystrokes do not
//! count: input that produces no output leaves the terminal parked. This is what
//! makes parking work while clients are attached, which is the common case for
//! agent workloads.
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
//! bytes.
//!
//! That identity has a consequence worth stating explicitly: **attaching to a
//! parked terminal does not unpark it.** The server streams the park file from
//! disk straight to the client and the terminal stays parked. Only a PTY read
//! unparks. See docs/PARKING.md.

const std = @import("std");
const session = @import("session.zig");

/// PTY-read-idle time after which a live terminal is parked.
pub const default_park_after_ns: u64 = 60 * std.time.ns_per_s;

/// Idle time after which an incremental scrollback compression step runs.
/// Distinct from parking: compression happens while the terminal is *live* and
/// only touches non-active, non-viewport pages.
pub const default_compress_after_ns: u64 = 250 * std.time.ns_per_ms;

pub const Config = struct {
    park_after_ns: u64 = default_park_after_ns,
    compress_after_ns: u64 = default_compress_after_ns,
    /// Park even while clients are attached. Because idleness is measured in
    /// PTY reads, an attached-but-silent terminal is still idle — and that is
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

/// Should this terminal be parked right now?
///
/// `pty_read_idle_ns` is time since the PTY last produced *output*. It is not a
/// general activity timestamp — keystrokes and client attachment must not reset
/// it, or terminals that are being typed into but producing nothing will never
/// park.
pub fn shouldPark(
    cfg: Config,
    residency: session.Residency,
    pty_read_idle_ns: u64,
    attached: u32,
) bool {
    if (residency != .live) return false;
    if (attached > 0 and !cfg.park_while_attached) return false;
    return pty_read_idle_ns >= cfg.park_after_ns;
}

test "shouldPark honours residency, PTY-read idle time and attachment" {
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
