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
const crypt = @import("crypt.zig");
const session = @import("session.zig");

/// PTY-read-idle time after which a live terminal is parked.
pub const default_park_after_ns: u64 = 60 * std.time.ns_per_s;

/// Idle time after which an incremental scrollback compression step runs.
/// Distinct from parking: compression happens while the terminal is *live* and
/// only touches non-active, non-viewport pages.
pub const default_compress_after_ns: u64 = 250 * std.time.ns_per_ms;

/// How long a terminal must go unobserved before its PTY leaves its dedicated
/// thread for the shared poller.
///
/// The hysteresis, and one-sided on purpose: promotion back to a thread is
/// immediate on attach, demotion waits. A person clicking between tabs must
/// not spawn and join a thread each time. See docs/PARKING.md, level 2.
pub const default_pty_park_unobserved_after_ns: u64 = 5 * std.time.ns_per_s;

/// How long a client must be quiet before its pipeline buffers are freed.
///
/// Level 3 of docs/PARKING.md. Kilobytes each, but multiplied by client count
/// at the scale this project is for. Ten seconds is long enough that it never
/// fires between a keystroke and its echo, and short enough that a window left
/// open overnight is not holding a megabyte per pane.
pub const default_client_park_after_ns: u64 = 10 * std.time.ns_per_s;

pub const Config = struct {
    park_after_ns: u64 = default_park_after_ns,
    compress_after_ns: u64 = default_compress_after_ns,
    pty_park_unobserved_after_ns: u64 = default_pty_park_unobserved_after_ns,
    client_park_after_ns: u64 = default_client_park_after_ns,
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
///       sessions/<sid>/meta.json             session id and name
///       sessions/<sid>/meta.json.tmp         staged write, renamed into place
///       sessions/<tid>/snapshot.gsnp         GHOSTSNP stream
///       sessions/<tid>/snapshot.gsnp.tmp     staged write, renamed on fsync
///
/// `meta.json` currently holds `{id, name}` and nothing else -- not the
/// terminal list docs/PARKING.md's table describes -- and it is **written but
/// never read back**: it is kept truthful so a restart-rebuild can be added,
/// but nothing rebuilds a session from it today. That read path is tracked
/// with the layout unification below.
///
/// Note the two id spaces sharing one directory level. `meta.json` is keyed by
/// *session* id and the snapshot files by *terminal* id, so session 3's
/// `meta.json` can sit beside terminal 3's `snapshot.gsnp` in `sessions/3/`.
/// The basenames never collide, so this is safe — but it is why nothing here
/// may ever `deleteTree` a `sessions/<id>` directory: a recursive delete keyed
/// by one id space would take an unrelated file from the other with it.
/// docs/PARKING.md documents the layout this should grow into.
pub const Store = struct {
    root: []const u8,
    /// The key park files are encrypted with, owned by the server.
    ///
    /// A pointer, not the key itself: a `Store` is copied into every terminal,
    /// and thirty-two bytes each is exactly the kind of per-terminal cost A6
    /// exists to notice. Null means write plaintext, which only tests do.
    key: ?*const crypt.Key = null,

    pub const snapshot_basename = "snapshot.gsnp";
    pub const staging_basename = "snapshot.gsnp.tmp";
    pub const meta_basename = "meta.json";
    pub const meta_staging_basename = "meta.json.tmp";
    pub const key_basename = "park.key";

    /// Park files are deflate-compressed.
    ///
    /// docs/PARKING.md calls for zstd, which is what Mitchell has recommended
    /// for snapshots. Zig 0.16 ships a zstd *decompressor* only, and pulling in
    /// a C zstd would be the project's first non-ghostty native dependency. So
    /// this is flate for now, behind one constant, and swapping it later is a
    /// local change.
    pub const Container: std.compress.flate.Container = .raw;

    /// Parking runs on a maintenance tick, not a user's critical path, but it
    /// does hold the terminal lock. Level 4 is the knee: most of the ratio for
    /// a fraction of the time of the higher levels.
    pub const compression_level = std.compress.flate.Compress.Options.level_4;

    /// Deflate needs a 64 KiB window on both sides.
    pub const window_len = std.compress.flate.max_window_len;

    pub fn ensureSessionDir(self: Store, io: std.Io, id: u64) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = try self.sessionDir(&buf, id);
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    /// The directory `id` keys. Both id spaces land here; see the note above.
    pub fn sessionDir(
        self: Store,
        buf: []u8,
        id: u64,
    ) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/sessions/{d}", .{ self.root, id });
    }

    /// A **terminal**'s park file. `id` is a terminal id, not a session id.
    pub fn snapshotPath(
        self: Store,
        buf: []u8,
        id: session.TerminalId,
    ) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(
            buf,
            "{s}/sessions/{d}/{s}",
            .{ self.root, id, snapshot_basename },
        );
    }

    /// Where a terminal's park file is staged before the rename.
    pub fn stagingPath(
        self: Store,
        buf: []u8,
        id: session.TerminalId,
    ) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(
            buf,
            "{s}/sessions/{d}/{s}",
            .{ self.root, id, staging_basename },
        );
    }

    /// A **session**'s metadata file. `id` is a session id.
    pub fn sessionMetaPath(
        self: Store,
        buf: []u8,
        id: session.Id,
    ) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(
            buf,
            "{s}/sessions/{d}/{s}",
            .{ self.root, id, meta_basename },
        );
    }

    /// Where a session's `meta.json` is staged before the rename.
    pub fn sessionMetaStagingPath(
        self: Store,
        buf: []u8,
        id: session.Id,
    ) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(
            buf,
            "{s}/sessions/{d}/{s}",
            .{ self.root, id, meta_staging_basename },
        );
    }

    pub fn keyPath(self: Store, buf: []u8) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.root, key_basename });
    }

    /// Bytes on disk for a parked terminal, or null if it is not parked.
    pub fn snapshotSize(self: Store, io: std.Io, id: session.TerminalId) ?u64 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.snapshotPath(&buf, id) catch return null;
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
        defer file.close(io);
        const info = file.stat(io) catch return null;
        return info.size;
    }

    /// Drop a terminal's park file, and the directory if that emptied it.
    ///
    /// The staging file too, and not for tidiness: `Terminal.park` stages
    /// through `snapshot.gsnp.tmp` and has no cleanup of its own, so a daemon
    /// killed mid-park leaves one behind. Without this line the terminal later
    /// retires, the `rmdir` below fails with ENOTEMPTY, and that directory
    /// leaks for the life of the machine -- which is the exact leak reaping
    /// exists to close, left open on the park half.
    ///
    /// The reap here runs on the maintenance thread and **outside**
    /// `Server.mutex`, keyed by *terminal* id. `writeSessionMeta` runs on a
    /// client's dispatch thread, under that mutex, keyed by *session* id, and
    /// creates the directory and the staging file as two steps. When the two
    /// ids happen to be equal -- routine on a fresh daemon, see the note on
    /// `Store` -- an interleaving of create-dir / rmdir / create-file makes
    /// that write fail with `FileNotFound`. Harmless today: the write is best
    /// effort, it warns, and nothing reads `meta.json` back. It stops being
    /// harmless when the restart-rebuild read path lands, so whoever adds it
    /// has to close this window -- it is recorded in that follow-up.
    pub fn discard(self: Store, io: std.Io, id: session.TerminalId) void {
        const cwd: std.Io.Dir = .cwd();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.snapshotPath(&buf, id)) |path| {
            cwd.deleteFile(io, path) catch {};
        } else |_| {}
        if (self.stagingPath(&buf, id)) |path| {
            cwd.deleteFile(io, path) catch {};
        } else |_| {}
        self.reapSessionDir(io, id);
    }

    /// Remove `sessions/<id>/` if nothing is left in it.
    ///
    /// The one directory removal in this file, and it is safe for exactly the
    /// reason `deleteTree` is not: `deleteDir` is `rmdir`, so it fails with
    /// `ENOTEMPTY` the moment the other id space still has something there --
    /// a same-numbered terminal's snapshot, which is R1 -- and with `ENOENT`
    /// when there was never a directory. Both are the correct outcome, which
    /// is why nothing here inspects the error. Without it every session and
    /// every terminal the daemon ever had leaves an empty directory behind
    /// forever.
    fn reapSessionDir(self: Store, io: std.Io, id: u64) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.sessionDir(&buf, id)) |dir| {
            std.Io.Dir.cwd().deleteDir(io, dir) catch {};
        } else |_| {}
    }

    /// What `meta.json` holds. A name, not scrollback, so it is written in
    /// plain text: `park.key` exists because F3 is about the contents of a
    /// terminal, and encrypting a session's label would only mean a daemon
    /// that lost its key could not tell you what it was holding.
    pub const SessionMeta = struct {
        id: session.Id,
        name: []const u8,
    };

    /// Persist a session's name.
    ///
    /// Validated here as well as at the protocol boundary, and that is not
    /// belt-and-braces: it is what makes the stack buffer below provably big
    /// enough. A validated name is at most `session.max_name_len` bytes of
    /// `[A-Za-z0-9._-]`, so JSON never escapes it and never re-encodes it as
    /// a byte array -- which is what `std.json` does with a non-UTF-8 string,
    /// producing a document this module's own parser then refuses. An
    /// unvalidated caller gets a loud error instead of a silent
    /// `NoSpaceLeft` or a file that cannot be read back.
    pub fn writeSessionMeta(self: Store, io: std.Io, id: session.Id, name: []const u8) !void {
        try session.validateName(name);
        try self.ensureSessionDir(io, id);

        var doc_buf: [session.max_name_len + 64]u8 = undefined;
        const doc = try std.fmt.bufPrint(&doc_buf, "{f}", .{std.json.fmt(SessionMeta{
            .id = id,
            .name = name,
        }, .{})});

        // Staged and renamed, the same shape `Terminal.park` uses -- because
        // the failure it rules out is the same one: a write straight to
        // `meta.json` truncates first, so a failure between the truncate and
        // the write leaves a zero-length file where a good name used to be.
        // A rename is atomic, so a reader sees the old name or the new one.
        //
        // No `sync` before the rename, deliberately, and that is where this
        // differs from parking. A park file is the only copy of a terminal's
        // scrollback and is worth an fsync per park; this is a label that the
        // registry already holds in memory and that nothing reads back yet.
        // The hazard being closed is a torn write, not power loss.
        //
        // **The staging path is one fixed name per session, so this function
        // is not safe to call concurrently for the same session.** Two writes
        // interleaving on `sessions/<sid>/meta.json.tmp` could publish either
        // document, or half of one. Every caller today is `Server`, under
        // `Server.mutex` -- which is the reason that call stays inside the
        // registry lock rather than being hoisted out of it for the sake of a
        // shorter critical section. Anything that changes needs a unique
        // staging name here first.
        var staging_buf: [std.fs.max_path_bytes]u8 = undefined;
        var final_buf: [std.fs.max_path_bytes]u8 = undefined;
        const staging = try self.sessionMetaStagingPath(&staging_buf, id);
        const final = try self.sessionMetaPath(&final_buf, id);

        const cwd: std.Io.Dir = .cwd();
        // Registered *before* the write, not after. `writeFile` is a create
        // followed by a write, so a failure part way through -- ENOSPC,
        // EDQUOT, EIO -- leaves the staging file behind, and an `errdefer`
        // below the call has not been reached yet to clean it up.
        errdefer cwd.deleteFile(io, staging) catch {};
        try cwd.writeFile(io, .{ .sub_path = staging, .data = doc });
        try cwd.rename(staging, cwd, final, io);
    }

    /// Drop a session's `meta.json`, and the directory if that emptied it.
    ///
    /// Named files only, never `deleteTree`. Terminal park files are keyed by
    /// *terminal* id in this same namespace, so a recursive delete here would
    /// cross two id spaces — discarding session 3 would take terminal 3's
    /// snapshot with it. See the note on `Store`, and `reapSessionDir` for why
    /// removing the directory itself is a different matter.
    /// Unlike `discard`, this reap races nothing: it is called from the same
    /// sweep that drops the registry entry, so no `writeSessionMeta` for this
    /// session can be in flight -- the mutex serializes them and a dropped
    /// session has no name left to write.
    pub fn discardSessionMeta(self: Store, io: std.Io, id: session.Id) void {
        const cwd: std.Io.Dir = .cwd();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.sessionMetaPath(&buf, id)) |path| {
            cwd.deleteFile(io, path) catch {};
        } else |_| {}
        // A staging file only exists if a write failed between the two steps
        // above; leaving it would keep the directory alive forever.
        if (self.sessionMetaStagingPath(&buf, id)) |path| {
            cwd.deleteFile(io, path) catch {};
        } else |_| {}
        self.reapSessionDir(io, id);
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

/// Mirrors `Terminal.Regime`, minus `stopped` -- that is a lifecycle state
/// rather than a choice this function gets to make.
pub const PtyRegime = enum { hot, polled };

/// Which IO regime a PTY belongs in right now. Level 2 of docs/PARKING.md.
///
/// Two rules, both from [MEM t=504]: a parked terminal's descriptor goes to the
/// poller, and so does one nobody is observing, because *"that 5 to 10% speed
/// isn't going to matter as much when a human isn't judging it"*.
///
/// `unobserved_ns` is time since the last subscriber left, and is zero while
/// one is attached. Note what is deliberately *not* here: PTY-read idleness. A
/// busy terminal nobody is watching still belongs in the poller — ten thousand
/// unwatched build logs should be ten thousand registrations, not ten thousand
/// threads. That is the whole reason this rule is separate from `shouldPark`.
pub fn ptyRegime(
    cfg: Config,
    residency: session.Residency,
    attached: u32,
    unobserved_ns: u64,
) PtyRegime {
    // Its state is on disk, so there is nothing in memory to feed.
    if (residency == .parked) return .polled;
    if (attached > 0) return .hot;
    return if (unobserved_ns >= cfg.pty_park_unobserved_after_ns) .polled else .hot;
}

test "ptyRegime parks the descriptor of anything nobody is judging" {
    const testing = std.testing;
    const cfg: Config = .{};
    const delay = default_pty_park_unobserved_after_ns;

    // Watched and live: worth a whole thread.
    try testing.expectEqual(PtyRegime.hot, ptyRegime(cfg, .live, 1, 0));
    try testing.expectEqual(PtyRegime.hot, ptyRegime(cfg, .rehydrating, 2, 0));

    // Parked, even with a client attached: attach is served from disk and does
    // not unpark, so there is still no thread's worth of work here.
    try testing.expectEqual(PtyRegime.polled, ptyRegime(cfg, .parked, 0, 0));
    try testing.expectEqual(PtyRegime.polled, ptyRegime(cfg, .parked, 3, 0));

    // Unobserved, but only once the delay has run.
    try testing.expectEqual(PtyRegime.hot, ptyRegime(cfg, .live, 0, 0));
    try testing.expectEqual(PtyRegime.hot, ptyRegime(cfg, .live, 0, delay - 1));
    try testing.expectEqual(PtyRegime.polled, ptyRegime(cfg, .live, 0, delay));

    // And an attach cancels it outright, however long it had been waiting.
    // Promotion immediate, demotion delayed: that asymmetry is the hysteresis.
    try testing.expectEqual(PtyRegime.hot, ptyRegime(cfg, .live, 1, delay * 100));
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
    try testing.expectEqualStrings(
        "/state/illogical/sessions/7/meta.json",
        try store.sessionMetaPath(&buf, 7),
    );
    try testing.expectEqualStrings(
        "/state/illogical/sessions/7/meta.json.tmp",
        try store.sessionMetaStagingPath(&buf, 7),
    );
}

test "a session's name is written, read back and discarded" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/illogical-meta-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const store: Store = .{ .root = root };
    // Creates the directory on the way: the first write for a session happens
    // when the session does, before anything has parked into it.
    try store.writeSessionMeta(io, 4, "work");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try store.sessionMetaPath(&path_buf, 4);
    var staging_buf: [std.fs.max_path_bytes]u8 = undefined;
    const staging = try store.sessionMetaStagingPath(&staging_buf, 4);
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try store.sessionDir(&dir_buf, 4);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096));
    defer gpa.free(bytes);

    const parsed = try std.json.parseFromSlice(Store.SessionMeta, gpa, bytes, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(session.Id, 4), parsed.value.id);
    try testing.expectEqualStrings("work", parsed.value.name);

    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, staging, .{}));

    // A rename overwrites rather than appending a second document -- and the
    // document really did arrive *by* the rename.
    //
    // The staging file is seeded first, with something neither write would
    // ever produce. Asserting only that no tmp is left afterwards proves
    // nothing: it is trivially true of a write straight to `meta.json`, which
    // is what this staging exists to avoid, and a full revert of it passed the
    // suite. Consuming a file that was already there cannot be faked -- a
    // direct write leaves this exact byte sequence sitting on disk.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staging, .data = "stale-from-a-crashed-write" });
    try store.writeSessionMeta(io, 4, "done");

    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096));
    defer gpa.free(after);
    const renamed = try std.json.parseFromSlice(Store.SessionMeta, gpa, after, .{});
    defer renamed.deinit();
    try testing.expectEqualStrings("done", renamed.value.name);
    // The staged path was written through and consumed, not sidestepped.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, staging, .{}));

    store.discardSessionMeta(io, 4);
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, path, .{}),
    );
    // And with nothing else in it, the directory goes too. Without this every
    // session the daemon ever had leaves an empty `sessions/<id>/` behind.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dir, .{}));

    // And discarding one that is not there is not an error: the sweep that
    // drops an empty session calls this whether or not it was ever written.
    store.discardSessionMeta(io, 4);
}

test "a name the server would refuse never reaches the park store" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/illogical-meta-bad-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const store: Store = .{ .root = root };

    // The sink's own check, not just the protocol boundary's. It is what makes
    // the stack buffer in `writeSessionMeta` provably sufficient: a name over
    // the limit would overflow it, and a non-UTF-8 one would make `std.json`
    // emit a byte array that `SessionMeta`'s parser then refuses -- both of
    // them silent, both of them reachable from `create` before this existed.
    try testing.expectError(
        error.NameInvalidChar,
        store.writeSessionMeta(io, 9, "has space"),
    );
    try testing.expectError(
        error.NameTooLong,
        store.writeSessionMeta(io, 9, "x" ** (session.max_name_len + 1)),
    );
    try testing.expectError(error.NameEmpty, store.writeSessionMeta(io, 9, ""));
    try testing.expectError(
        error.NameInvalidChar,
        store.writeSessionMeta(io, 9, "caf\xc3\xa9\xff"),
    );

    // Refused before anything was created: no file, and not even a directory.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try store.sessionMetaPath(&path_buf, 9);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try store.sessionDir(&dir_buf, 9);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dir, .{}));

    // A name at the limit is accepted, so the refusal above is the rule and
    // not an off-by-one.
    try store.writeSessionMeta(io, 9, "x" ** session.max_name_len);
}

test "discarding a session's meta leaves a terminal's park file in the same directory" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/illogical-meta-r1-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const store: Store = .{ .root = root };

    // R1: session ids and terminal ids share `sessions/<id>/`, and both start
    // at 1 — so session 1's meta and terminal 1's snapshot are the *same
    // directory*. This is the case a `deleteTree` in `discardSessionMeta`
    // would silently destroy, and it is reachable on the first session the
    // daemon ever creates.
    try store.writeSessionMeta(io, 1, "work");
    var snap_buf: [std.fs.max_path_bytes]u8 = undefined;
    const snapshot = try store.snapshotPath(&snap_buf, 1);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = snapshot, .data = "GHOSTSNP-ish" });

    store.discardSessionMeta(io, 1);

    try testing.expectEqual(@as(u64, "GHOSTSNP-ish".len), store.snapshotSize(io, 1).?);
    // And the directory survives with it. `reapSessionDir` is `rmdir`, so the
    // snapshot makes it fail with ENOTEMPTY -- which is the whole reason
    // reaping the directory is safe where a `deleteTree` would not be.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try store.sessionDir(&dir_buf, 1);
    try std.Io.Dir.cwd().access(io, dir, .{});

    // The other order, too: once the terminal's park file goes, the directory
    // that outlived the session finally goes with it.
    store.discard(io, 1);
    try testing.expect(store.snapshotSize(io, 1) == null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dir, .{}));
}
