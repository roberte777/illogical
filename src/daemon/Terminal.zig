//! One terminal: a PTY, the authoritative libghostty-vt state derived from it,
//! and the set of clients subscribed to its raw output.
//!
//! Threading follows docs/ARCHITECTURE.md: a *hot* terminal owns a dedicated OS
//! thread blocked on `read()`. That is measurably the fastest way to move PTY
//! bytes, and it is why this is not an event loop.
//!
//! The reader thread does two things with every chunk it reads, in this order:
//!
//!   1. Applies it to our own terminal state, under `mutex`.
//!   2. Fans the *same, unmodified* bytes out to every subscriber.
//!
//! Step 2 never re-encodes anything. That is goal G2.

const Terminal = @This();

const std = @import("std");
const sys = illogical.sys;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const ghostty = @import("ghostty-vt");
const illogical = @import("illogical");
const pty = illogical.pty;
const session = illogical.session;

const log = std.log.scoped(.terminal);

const read_buf_size = 64 * 1024;

/// Cap on the unfinished-VT-input suffix we will carry in a snapshot. Matches
/// libghostty-vt's own default (its largest built-in APC protocol buffer).
const max_continuation_bytes = 65 * 1024 * 1024;

pub const Subscriber = struct {
    ctx: *anyopaque,
    /// Deliver raw PTY bytes. Must not block for long and must not call back
    /// into this terminal.
    writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    /// The child exited.
    exitFn: *const fn (ctx: *anyopaque, code: i32) void,

    fn write(self: Subscriber, bytes: []const u8) void {
        self.writeFn(self.ctx, bytes);
    }
};

gpa: Allocator,
io: std.Io,
/// Where this terminal's snapshot lives when parked.
store: illogical.park.Store,
park_config: illogical.park.Config,
id: session.TerminalId,
session_id: session.Id,
name: []u8,
command: []u8,
cwd: []u8,

pty_pair: pty.Pty,
child: sys.pid_t,

/// Guards `vt`, `stream` and the size/residency fields below. libghostty-vt
/// requires that a terminal is never touched by two threads at once.
mutex: illogical.thread.Mutex = .{},
tiny_io: ghostty.TinyIo,
/// Null while parked: the whole point is that a parked terminal holds no
/// terminal state in memory.
vt: ?ghostty.Terminal,
/// Persistent parser state. Must outlive individual writes so escape sequences
/// split across `read()` boundaries are handled correctly. Freed with `vt`.
stream: ?ghostty.TerminalStream,
/// Set while history pages are being restored on a background thread.
rehydration: ?*Rehydration = null,
/// Cached compression activity token; when it changes the idle timer restarts.
compression_activity: u64 = 0,
compression_idle_since_ns: u64 = 0,
cols: u16,
rows: u16,
residency: session.Residency = .live,
exit_code: ?i32 = null,
/// Monotonic timestamp of the last PTY *read*. This — not general activity —
/// is what drives parking. See docs/PARKING.md.
last_read_ns: u64,

subscribers: std.ArrayList(Subscriber) = .empty,

thread: ?std.Thread = null,
running: std.atomic.Value(bool) = .init(false),
/// Set once the reader thread has finished and the child has been reaped, so
/// the server can retire this terminal. The reader thread cannot destroy its
/// own terminal -- that would join itself -- so retiring happens on the
/// maintenance tick.
finished: std.atomic.Value(bool) = .init(false),

pub const SpawnOptions = struct {
    io: std.Io,
    store: illogical.park.Store,
    park_config: illogical.park.Config = .{},
    id: session.TerminalId,
    session_id: session.Id,
    name: []const u8,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    cols: u16 = 80,
    rows: u16 = 24,
    max_scrollback_bytes: ?usize = 50 * 1024 * 1024,
};

pub fn create(gpa: Allocator, opts: SpawnOptions) !*Terminal {
    const self = try gpa.create(Terminal);
    errdefer gpa.destroy(self);

    var p = try pty.Pty.open(.{ .cols = opts.cols, .rows = opts.rows });
    errdefer p.deinit();

    const name = try gpa.dupe(u8, opts.name);
    errdefer gpa.free(name);
    const command = try gpa.dupe(u8, opts.argv[0]);
    errdefer gpa.free(command);
    const cwd = try gpa.dupe(u8, opts.cwd orelse "");
    errdefer gpa.free(cwd);

    self.* = .{
        .gpa = gpa,
        .io = opts.io,
        .store = opts.store,
        .park_config = opts.park_config,
        .id = opts.id,
        .session_id = opts.session_id,
        .name = name,
        .command = command,
        .cwd = cwd,
        .pty_pair = p,
        .child = undefined,
        .tiny_io = .init,
        .vt = undefined,
        .stream = undefined,
        .cols = opts.cols,
        .rows = opts.rows,
        .last_read_ns = sys.monotonicNs(),
    };

    self.vt = try .init(self.tiny_io.io(), gpa, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .max_scrollback_bytes = opts.max_scrollback_bytes,
    });
    errdefer self.vt.?.deinit(gpa);

    // Continuation tracking must be on *before* the input that produces an
    // unfinished parser state is written -- there is no retroactive path. So we
    // enable it unconditionally at creation. See docs/PARKING.md.
    self.stream = .init(.{
        .allocator = gpa,
        .handler = self.vt.?.vtHandler(),
        .continuation_max_bytes = max_continuation_bytes,
    });
    self.stream.?.handler.effects = effects;
    _ = &effects;

    self.child = try self.spawnChild(opts);
    return self;
}

const effects: ghostty.TerminalStream.Handler.Effects = .{
    .write_pty = writePtyEffect,
    .bell = null,
    .desktop_notification = null,
    .drag_and_drop = null,
    .color_scheme = null,
    .device_attributes = null,
    .enquiry = null,
    .size = sizeEffect,
    .xtversion = null,
    .title_changed = null,
    .pwd_changed = null,
    .progress_report = null,
    .clipboard_write = null,
    .clipboard_read = null,
};

fn spawnChild(self: *Terminal, opts: SpawnOptions) !sys.pid_t {
    const gpa = self.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argv = try arena.allocSentinel(?[*:0]const u8, opts.argv.len, null);
    for (opts.argv, 0..) |a, i| argv[i] = try arena.dupeZ(u8, a);

    const cwdz: ?[*:0]const u8 = if (opts.cwd) |d|
        (try arena.dupeZ(u8, d)).ptr
    else
        null;

    return self.pty_pair.spawn(argv.ptr, pty.childEnv(), cwdz);
}

pub fn destroy(self: *Terminal) void {
    self.stop();
    if (!self.finished.load(.acquire)) self.pty_pair.deinit();
    self.mutex.lock();
    if (self.stream) |*stream| stream.deinit();
    if (self.vt) |*vt| vt.deinit(self.gpa);
    self.stream = null;
    self.vt = null;
    self.mutex.unlock();
    self.subscribers.deinit(self.gpa);
    self.gpa.free(self.name);
    self.gpa.free(self.command);
    self.gpa.free(self.cwd);
    self.gpa.destroy(self);
}

/// Start the dedicated reader thread. See docs/OPTIMIZATIONS.md A3.
pub fn start(self: *Terminal) !void {
    if (self.running.load(.acquire)) return;
    self.running.store(true, .release);
    self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
}

pub fn stop(self: *Terminal) void {
    if (self.running.swap(false, .acq_rel)) {
        // Closing the master makes the blocking read return. Only do this if
        // we were still running; a terminal whose child already exited has
        // closed it in the reader thread.
        sys.closeFd(self.pty_pair.master);
    }
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
}

fn readLoop(self: *Terminal) void {
    var buf: [read_buf_size]u8 = undefined;
    while (self.running.load(.acquire)) {
        const n = sys.readFd(self.pty_pair.master, &buf) catch break;
        if (n == 0) break;
        const bytes = buf[0..n];

        // Applying to our state and fanning out happen under one lock, so
        // that `attach` can insert itself at an exact point in the byte stream
        // and no client can miss or double-apply a chunk.
        self.mutex.lock();
        // A read is exactly what unparks a terminal. Do it before applying,
        // or the bytes that woke us would be dropped on the floor.
        if (self.residency == .parked) {
            self.unparkLocked() catch |err|
                log.err("terminal {d} failed to unpark: {t}", .{ self.id, err });
        }
        if (self.stream) |*stream| stream.nextSlice(bytes);
        self.last_read_ns = sys.monotonicNs();
        // The exact same bytes, to everyone. No re-encoding. (G2)
        for (self.subscribers.items) |sub| sub.write(bytes);
        self.mutex.unlock();
    }
    self.reap();
}

fn reap(self: *Terminal) void {
    const code = sys.wait(self.child);
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.residency = .exited;
        self.exit_code = code;
        for (self.subscribers.items) |s| s.exitFn(s.ctx, code);
    }
    // Last, so the server never sees `finished` before the exit has been
    // reported to everyone watching.
    self.running.store(false, .release);
    self.finished.store(true, .release);
}

/// Attach a client: subscribe it and stream it a snapshot, atomically.
///
/// The terminal lock is held for the whole operation, which is exactly the
/// "server pauses PTY processing while the client synchronizes" step from
/// docs/PROTOCOL.md. Because the reader thread also fans out under this lock,
/// the client is guaranteed to receive every byte after the snapshot and none
/// from before it -- no offset bookkeeping required.
pub fn attach(self: *Terminal, sub: Subscriber, snapshot_writer: *std.Io.Writer) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    try self.subscribers.append(self.gpa, sub);
    errdefer self.removeSubscriberLocked(sub.ctx);

    // A parked terminal is served from disk and stays parked (docs/PARKING.md).
    if (self.residency == .parked) {
        return self.streamParkFileLocked(self.store, snapshot_writer);
    }
    try self.encodeSnapshotLocked(snapshot_writer);
}

pub fn subscribe(self: *Terminal, sub: Subscriber) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.subscribers.append(self.gpa, sub);
}

pub fn unsubscribe(self: *Terminal, ctx: *anyopaque) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.removeSubscriberLocked(ctx);
}

fn removeSubscriberLocked(self: *Terminal, ctx: *anyopaque) void {
    var i: usize = 0;
    while (i < self.subscribers.items.len) {
        if (self.subscribers.items[i].ctx == ctx) {
            _ = self.subscribers.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn attachedCount(self: *Terminal) u32 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return @intCast(self.subscribers.items.len);
}

/// Close this terminal: hang up its process group.
///
/// SIGTERM is the wrong signal here. An interactive shell ignores it, so
/// "close this tab" did nothing for the common case of a bare `$SHELL`. SIGHUP
/// is what a terminal sends when its window goes away, and shells exit on it.
/// It goes to the process group so the shell's jobs go down with it.
pub fn hangup(self: *Terminal) void {
    sys.signalGroup(self.child, sys.SIGHUP);
}

/// Write client input to the PTY. One writer: every client's input funnels
/// through here. (docs/PROTOCOL.md C2)
pub fn writeInput(self: *Terminal, bytes: []const u8) !void {
    try sys.writeAll(self.pty_pair.master, bytes);
}

pub fn resize(self: *Terminal, cols: u16, rows: u16) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (cols == self.cols and rows == self.rows) return;
    if (self.vt) |*vt| try vt.resize(self.gpa, .{ .cols = cols, .rows = rows });
    try self.pty_pair.setSize(.{ .cols = cols, .rows = rows });
    self.cols = cols;
    self.rows = rows;
}

/// Encode a complete snapshot of this terminal to `writer`.
///
/// The caller must not be holding `mutex`; this takes it, because libghostty-vt
/// forbids mutating the terminal during an encode. This is the "pause PTY
/// processing" step of the attach handshake (docs/PROTOCOL.md).
pub fn snapshot(self: *Terminal, writer: *std.Io.Writer) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.encodeSnapshotLocked(writer);
}

fn encodeSnapshotLocked(self: *Terminal, writer: *std.Io.Writer) !void {
    // A grounded parser needs no continuation. Otherwise carry the minimal
    // suffix so the client resumes *inside* the unfinished sequence.
    var cont_buf: std.ArrayList(u8) = .empty;
    defer cont_buf.deinit(self.gpa);

    const stream = &(self.stream orelse return error.TerminalParked);
    const vt = &(self.vt orelse return error.TerminalParked);

    const cont: ghostty.snapshot.Continuation = if (stream.ground()) .ground else blk: {
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &cont_buf);
        stream.writeContinuation(&aw.writer) catch |err| switch (err) {
            // Tracking is on, so this only happens if the tracker gave up.
            // Falling back to ground loses the partial sequence but keeps the
            // snapshot valid, which is the better failure.
            error.ContinuationDisabled, error.ContinuationUnavailable => {
                log.warn("continuation unavailable, encoding as ground", .{});
                break :blk .ground;
            },
            else => return err,
        };
        cont_buf = aw.toArrayList();
        break :blk .{ .bytes = cont_buf.items };
    };

    try ghostty.snapshot.encode(self.gpa, writer, vt, .{ .continuation = cont });
}

/// The rendered screen as plain text. Caller owns the result.
pub fn plainText(self: *Terminal, alloc: Allocator) ![]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const vt = &(self.vt orelse return error.TerminalParked);
    return vt.plainString(alloc);
}

/// Nanoseconds since the PTY last produced output.
pub fn ptyReadIdleNs(self: *Terminal) u64 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const now = sys.monotonicNs();
    return if (now > self.last_read_ns) now - self.last_read_ns else 0;
}

pub fn summary(self: *Terminal) session.TerminalSummary {
    self.mutex.lock();
    const residency = self.residency;
    const exit_code = self.exit_code;
    const cols = self.cols;
    const rows = self.rows;
    self.mutex.unlock();

    return .{
        .id = self.id,
        .session = self.session_id,
        .name = self.name,
        .command = self.command,
        .cwd = self.cwd,
        .cols = cols,
        .rows = rows,
        .residency = residency,
        .attached = self.attachedCount(),
        .pty_read_idle_ns = self.ptyReadIdleNs(),
        .exit_code = exit_code,
    };
}

// -- parking ---------------------------------------------------------------
//
// See docs/PARKING.md. Three properties matter and each is load-bearing:
//
//   * "Idle" means no PTY *reads*. Keystrokes do not count, which is what lets
//     an attached, focused terminal stay parked while it produces nothing.
//   * Unparking is two-phase: `ready` restores the active screen on the hot
//     path, history pages follow on a pool thread.
//   * Attaching to a parked terminal does **not** unpark it. The park file and
//     the attach payload are the same bytes, so we stream from disk.

/// Background restore of history pages after `ready`.
///
/// Heap-allocated because the decoder holds a pointer into the decompressor,
/// which holds one into the file reader. The thread owns this and frees it.
const Rehydration = struct {
    terminal: *Terminal,
    file: std.Io.File,
    file_reader: std.Io.File.Reader,
    decompress: flate.Decompress,
    decoder: ghostty.snapshot.Decoder,
    file_buf: []u8,
    window: []u8,
    thread: ?std.Thread = null,

    fn destroy(self: *Rehydration) void {
        const gpa = self.terminal.gpa;
        self.file.close(self.terminal.io);
        gpa.free(self.file_buf);
        gpa.free(self.window);
        gpa.destroy(self);
    }
};

/// Snapshot to disk and release the in-memory terminal.
pub fn park(self: *Terminal) !void {
    const store = self.store;
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.residency != .live) return;

    try store.ensureSessionDir(self.io, self.id);

    var staging_buf: [std.fs.max_path_bytes]u8 = undefined;
    var final_buf: [std.fs.max_path_bytes]u8 = undefined;
    const staging = try store.stagingPath(&staging_buf, self.id);
    const final = try store.snapshotPath(&final_buf, self.id);

    const cwd: std.Io.Dir = .cwd();
    {
        const file = try cwd.createFile(self.io, staging, .{ .truncate = true });
        errdefer file.close(self.io);

        var out_buf: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(self.io, &out_buf);

        const window = try self.gpa.alloc(u8, illogical.park.Store.window_len);
        defer self.gpa.free(window);
        var compress = try flate.Compress.init(
            &file_writer.interface,
            window,
            illogical.park.Store.Container,
            illogical.park.Store.compression_level,
        );

        try self.encodeSnapshotLocked(&compress.writer);
        try compress.finish();
        try file_writer.interface.flush();

        // Durable before the rename, so a crash leaves either the previous
        // good snapshot or this one, never a torn file.
        try file.sync(self.io);
        file.close(self.io);
    }
    try cwd.rename(staging, cwd, final, self.io);

    if (self.stream) |*stream| stream.deinit();
    if (self.vt) |*vt| vt.deinit(self.gpa);
    self.stream = null;
    self.vt = null;
    self.residency = .parked;

    log.debug("parked terminal {d}", .{self.id});
}

/// Restore from disk. Returns once the terminal is renderable; history pages
/// keep arriving on a background thread.
pub fn unpark(self: *Terminal) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.unparkLocked();
}

fn unparkLocked(self: *Terminal) !void {
    const store = self.store;
    if (self.residency != .parked) return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try store.snapshotPath(&path_buf, self.id);

    const rehydration = try self.gpa.create(Rehydration);
    errdefer self.gpa.destroy(rehydration);

    const file_buf = try self.gpa.alloc(u8, 64 * 1024);
    errdefer self.gpa.free(file_buf);
    const window = try self.gpa.alloc(u8, illogical.park.Store.window_len);
    errdefer self.gpa.free(window);

    const file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
    errdefer file.close(self.io);

    rehydration.* = .{
        .terminal = self,
        .file = file,
        .file_reader = undefined,
        .decompress = undefined,
        .decoder = undefined,
        .file_buf = file_buf,
        .window = window,
    };
    // Each of these retains a pointer to the previous, so they must be built
    // in place at their final addresses.
    rehydration.file_reader = file.reader(self.io, rehydration.file_buf);
    rehydration.decompress = .init(
        &rehydration.file_reader.interface,
        illogical.park.Store.Container,
        rehydration.window,
    );
    rehydration.decoder = .init(&rehydration.decompress.reader);

    // Phase 1: the renderable prefix. This is the number that matters.
    var decoded = try rehydration.decoder.ready(self.gpa, self.tiny_io.io(), .{
        .max_continuation_bytes = max_continuation_bytes,
    });
    defer decoded.deinit(self.gpa);

    self.vt = decoded.toOwned();
    errdefer if (self.vt) |*vt| {
        vt.deinit(self.gpa);
        self.vt = null;
    };

    self.stream = .init(.{
        .allocator = self.gpa,
        .handler = self.vt.?.vtHandler(),
        .continuation_max_bytes = max_continuation_bytes,
    });
    self.stream.?.handler.effects = effects;

    // Resume inside whatever escape sequence was in flight when we parked.
    switch (decoded.continuation) {
        .ground => {},
        .bytes => |bytes| self.stream.?.nextSlice(bytes),
    }

    self.residency = .rehydrating;
    self.rehydration = rehydration;
    rehydration.thread = std.Thread.spawn(.{}, restoreHistory, .{rehydration}) catch |err| {
        // Without the background thread we still have a correct, renderable
        // terminal -- just no scrollback.
        log.warn("history restore thread failed: {t}", .{err});
        self.residency = .live;
        self.rehydration = null;
        rehydration.destroy();
        return;
    };
}

/// Phase 2: prepend history pages, newest first, off the critical path.
fn restoreHistory(r: *Rehydration) void {
    const self = r.terminal;
    while (true) {
        self.mutex.lock();
        if (self.residency != .rehydrating) {
            self.mutex.unlock();
            break;
        }
        const vt = &(self.vt orelse {
            self.mutex.unlock();
            break;
        });
        const more = r.decoder.next(self.gpa, vt) catch |err| {
            log.warn("history restore stopped: {t}", .{err});
            self.mutex.unlock();
            break;
        };
        self.mutex.unlock();
        if (more == null) break;
    }

    self.mutex.lock();
    if (self.residency == .rehydrating) self.residency = .live;
    self.rehydration = null;
    self.mutex.unlock();
    r.destroy();
}

/// Write this terminal's snapshot to `writer` for an attaching client.
///
/// A parked terminal is served straight from disk and stays parked, so a client
/// hammering attach/detach never wakes anything.
pub fn serveSnapshot(self: *Terminal, writer: *std.Io.Writer) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.residency == .parked) return self.streamParkFileLocked(self.store, writer);
    return self.encodeSnapshotLocked(writer);
}

fn streamParkFileLocked(
    self: *Terminal,
    store: illogical.park.Store,
    writer: *std.Io.Writer,
) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try store.snapshotPath(&path_buf, self.id);

    const file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
    defer file.close(self.io);

    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(self.io, &file_buf);

    const window = try self.gpa.alloc(u8, illogical.park.Store.window_len);
    defer self.gpa.free(window);
    var decompress: flate.Decompress = .init(
        &file_reader.interface,
        illogical.park.Store.Container,
        window,
    );

    _ = try decompress.reader.streamRemaining(writer);
}

/// One bounded step of scrollback compression, for an idle-ish terminal.
///
/// libghostty-vt creates no timer and no thread for this: the embedder decides
/// when. Incremental mode does bounded work; MODE_FULL can stall on a large
/// scrollback and must never run here.
pub fn compressStep(self: *Terminal) void {
    const cfg = self.park_config;
    self.mutex.lock();
    defer self.mutex.unlock();
    const vt = &(self.vt orelse return);

    const activity = vt.compressionActivity();
    const now = sys.monotonicNs();
    if (activity != self.compression_activity) {
        // New content: restart the idle delay.
        self.compression_activity = activity;
        self.compression_idle_since_ns = now;
        return;
    }
    if (now -| self.compression_idle_since_ns < cfg.compress_after_ns) return;

    switch (vt.compress(.incremental)) {
        // Still work to do; the next tick continues it.
        .pending => {},
        // Nothing more until the activity token changes.
        .complete => self.compression_idle_since_ns = now +| cfg.compress_after_ns,
        // No OS primitive to discard physical pages here (not macOS or
        // 64-bit Linux). Stop asking.
        .unsupported => self.compression_idle_since_ns = std.math.maxInt(u64),
    }
}

// -- effects ---------------------------------------------------------------
//
// The server answers terminal queries itself, with zero or fifty clients
// attached. Clients never do: they would race each other and produce duplicate
// replies. See docs/ARCHITECTURE.md#terminal-queries.

fn fromHandler(h: *ghostty.TerminalStream.Handler) *Terminal {
    const stream: *ghostty.TerminalStream = @fieldParentPtr("handler", h);
    const opt: *?ghostty.TerminalStream = @ptrCast(stream);
    return @fieldParentPtr("stream", opt);
}

fn writePtyEffect(h: *ghostty.TerminalStream.Handler, data: []const u8) void {
    const self = fromHandler(h);
    // We already hold `mutex` here: this runs inside `stream.nextSlice`.
    sys.writeAll(self.pty_pair.master, data) catch |err| {
        log.warn("failed writing query response to pty: {t}", .{err});
    };
}

fn sizeEffect(h: *ghostty.TerminalStream.Handler) ?ghostty.size_report.Size {
    const self = fromHandler(h);
    return .{
        .rows = self.rows,
        .columns = self.cols,
        // We do not know the client's font metrics, and clients may disagree.
        // Reporting zero is the honest answer for a headless server.
        .cell_width = 0,
        .cell_height = 0,
    };
}

// -- tests -----------------------------------------------------------------

test "pty output reaches terminal state and survives a snapshot round trip" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const marker = "ILLOGICAL_SNAPSHOT_MARKER";
    const t = try Terminal.create(gpa, .{
        .io = threaded.io(),
        .store = .{ .root = "/tmp/illogical-unused" },
        .id = 1,
        .session_id = 1,
        .name = "test",
        .argv = &.{ "/bin/sh", "-c", "printf '" ++ marker ++ "\\n'; sleep 5" },
        .cols = 80,
        .rows = 24,
    });
    defer t.destroy();
    try t.start();

    // Wait for the child's output to land in our terminal state.
    var waited: usize = 0;
    while (waited < 3000) : (waited += 10) {
        t.mutex.lock();
        const text = try t.vt.?.plainString(gpa);
        t.mutex.unlock();
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, marker) != null) break;
        sys.sleepNs(10 * std.time.ns_per_ms);
    } else return error.MarkerNeverArrived;

    // Snapshot it.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    try t.snapshot(&aw.writer);
    try aw.writer.flush();
    buf = aw.toArrayList();
    try testing.expect(buf.items.len > 0);
    try testing.expectEqualStrings("GHOSTSNP", buf.items[0..8]);

    // Decode it into a fresh terminal, exactly as a client would, and confirm
    // the screen came back.
    var tiny: ghostty.TinyIo = .init;
    var reader: std.Io.Reader = .fixed(buf.items);
    var decoder: ghostty.snapshot.Decoder = .init(&reader);
    var decoded = try decoder.ready(gpa, tiny.io(), .{
        .max_continuation_bytes = max_continuation_bytes,
    });
    defer decoded.deinit(gpa);

    const restored = &(decoded.terminal orelse return error.NoTerminal);
    const text = try restored.plainString(gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, marker) != null);
}

test "idle clock tracks PTY reads, not wall time" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const t = try Terminal.create(gpa, .{
        .io = threaded.io(),
        .store = .{ .root = "/tmp/illogical-unused" },
        .id = 2,
        .session_id = 1,
        .name = "idle",
        .argv = &.{ "/bin/sh", "-c", "sleep 5" },
        .cols = 80,
        .rows = 24,
    });
    defer t.destroy();
    try t.start();

    sys.sleepNs(50 * std.time.ns_per_ms);
    // No output has been produced, so the terminal is idle by our definition
    // even though it was just created and its child is running.
    try testing.expect(t.ptyReadIdleNs() >= 40 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 0), t.attachedCount());
}

test "park writes a snapshot, unpark restores the screen" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/illogical-park-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const marker = "PARK_ROUND_TRIP_MARKER";
    const t = try Terminal.create(gpa, .{
        .io = io,
        .store = .{ .root = root },
        .id = 1,
        .session_id = 1,
        .name = "park",
        .argv = &.{ "/bin/sh", "-c", "printf '" ++ marker ++ "\\n'; sleep 10" },
        .cols = 80,
        .rows = 24,
    });
    defer t.destroy();
    try t.start();

    // Wait for the child's output to reach our state.
    var waited: usize = 0;
    while (waited < 3000) : (waited += 10) {
        const text = t.plainText(gpa) catch {
            sys.sleepNs(10 * std.time.ns_per_ms);
            continue;
        };
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, marker) != null) break;
        sys.sleepNs(10 * std.time.ns_per_ms);
    } else return error.MarkerNeverArrived;

    // Park it.
    try t.park();
    try testing.expectEqual(session.Residency.parked, t.summary().residency);
    // No terminal state in memory any more.
    try testing.expect(t.vt == null);
    try testing.expect(t.stream == null);
    // And a snapshot on disk.
    const size = t.store.snapshotSize(io, t.id) orelse return error.NoSnapshotOnDisk;
    try testing.expect(size > 0);

    // Peeking must not wake it.
    try testing.expectError(error.TerminalParked, t.plainText(gpa));
    try testing.expectEqual(session.Residency.parked, t.summary().residency);

    // Unpark restores the screen.
    try t.unpark();
    var settle: usize = 0;
    while (settle < 2000) : (settle += 10) {
        if (t.summary().residency == .live) break;
        sys.sleepNs(10 * std.time.ns_per_ms);
    }
    const text = try t.plainText(gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, marker) != null);
}

test "attaching to a parked terminal serves from disk and leaves it parked" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/illogical-attach-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const marker = "SERVED_FROM_DISK";
    const t = try Terminal.create(gpa, .{
        .io = io,
        .store = .{ .root = root },
        .id = 2,
        .session_id = 1,
        .name = "disk",
        .argv = &.{ "/bin/sh", "-c", "printf '" ++ marker ++ "\\n'; sleep 10" },
        .cols = 80,
        .rows = 24,
    });
    defer t.destroy();
    try t.start();

    var waited: usize = 0;
    while (waited < 3000) : (waited += 10) {
        const text = t.plainText(gpa) catch break;
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, marker) != null) break;
        sys.sleepNs(10 * std.time.ns_per_ms);
    }
    try t.park();

    // Serve a snapshot the way an attaching client would.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    try t.serveSnapshot(&aw.writer);
    try aw.writer.flush();
    buf = aw.toArrayList();

    // It is a real snapshot...
    try testing.expect(buf.items.len > 0);
    try testing.expectEqualStrings("GHOSTSNP", buf.items[0..8]);

    // ...and the terminal is still parked. This is the property that makes
    // attach/detach cycling free.
    try testing.expectEqual(session.Residency.parked, t.summary().residency);
    try testing.expect(t.vt == null);

    // What we served decodes back to the same screen.
    var tiny: ghostty.TinyIo = .init;
    var reader: std.Io.Reader = .fixed(buf.items);
    var decoder: ghostty.snapshot.Decoder = .init(&reader);
    var decoded = try decoder.ready(gpa, tiny.io(), .{
        .max_continuation_bytes = max_continuation_bytes,
    });
    defer decoded.deinit(gpa);
    const restored = &(decoded.terminal orelse return error.NoTerminal);
    const text = try restored.plainString(gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, marker) != null);
}

test "scrollback compression reports what it actually does" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var tiny: ghostty.TinyIo = .init;
    var vt: ghostty.Terminal = try .init(tiny.io(), gpa, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 50 * 1024 * 1024,
    });
    defer vt.deinit(gpa);

    var stream = vt.vtStream();
    defer stream.deinit();

    // Fill well past the active area so there is cold scrollback to compress.
    var line: [96]u8 = undefined;
    for (0..10_000) |i| {
        const text = try std.fmt.bufPrint(
            &line,
            "line {d} ---- filler text to make this a realistic terminal line\r\n",
            .{i},
        );
        stream.nextSlice(text);
    }

    // Incremental steps must be bounded and must terminate. If the platform
    // has no primitive for discarding physical pages, `unsupported` is the
    // honest answer and the scheduler stops asking.
    var steps: usize = 0;
    var last: ghostty.Terminal.CompressionResult = .pending;
    while (steps < 2000) : (steps += 1) {
        last = vt.compress(.incremental);
        if (last != .pending) break;
    }
    try testing.expect(last == .complete or last == .unsupported);
    try testing.expect(steps < 2000);
}
