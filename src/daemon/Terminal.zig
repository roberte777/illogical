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
vt: ghostty.Terminal,
/// Persistent parser state. Must outlive individual writes so escape sequences
/// split across `read()` boundaries are handled correctly.
stream: ghostty.TerminalStream,
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

pub const SpawnOptions = struct {
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
    errdefer self.vt.deinit(gpa);

    // Continuation tracking must be on *before* the input that produces an
    // unfinished parser state is written -- there is no retroactive path. So we
    // enable it unconditionally at creation. See docs/PARKING.md.
    self.stream = .init(.{
        .allocator = gpa,
        .handler = self.vt.vtHandler(),
        .continuation_max_bytes = max_continuation_bytes,
    });
    self.stream.handler.effects = .{
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

    self.child = try self.spawnChild(opts);
    return self;
}

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

    return self.pty_pair.spawn(argv.ptr, &pty.base_env, cwdz);
}

pub fn destroy(self: *Terminal) void {
    self.stop();
    self.pty_pair.deinit();
    self.mutex.lock();
    self.stream.deinit();
    self.vt.deinit(self.gpa);
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
    if (!self.running.load(.acquire)) return;
    self.running.store(false, .release);
    // Closing the master makes the blocking read return.
    sys.closeFd(self.pty_pair.master);
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
        self.stream.nextSlice(bytes);
        self.last_read_ns = sys.monotonicNs();
        // The exact same bytes, to everyone. No re-encoding. (G2)
        for (self.subscribers.items) |sub| sub.write(bytes);
        self.mutex.unlock();
    }
    self.reap();
}

fn reap(self: *Terminal) void {
    const code = sys.wait(self.child);
    self.mutex.lock();
    defer self.mutex.unlock();
    self.residency = .exited;
    self.exit_code = code;
    for (self.subscribers.items) |s| s.exitFn(s.ctx, code);
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

/// Write client input to the PTY. One writer: every client's input funnels
/// through here. (docs/PROTOCOL.md C2)
pub fn writeInput(self: *Terminal, bytes: []const u8) !void {
    try sys.writeAll(self.pty_pair.master, bytes);
}

pub fn resize(self: *Terminal, cols: u16, rows: u16) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (cols == self.cols and rows == self.rows) return;
    try self.vt.resize(self.gpa, .{ .cols = cols, .rows = rows });
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

    const cont: ghostty.snapshot.Continuation = if (self.stream.ground()) .ground else blk: {
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &cont_buf);
        self.stream.writeContinuation(&aw.writer) catch |err| switch (err) {
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

    try ghostty.snapshot.encode(self.gpa, writer, &self.vt, .{ .continuation = cont });
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

// -- effects ---------------------------------------------------------------
//
// The server answers terminal queries itself, with zero or fifty clients
// attached. Clients never do: they would race each other and produce duplicate
// replies. See docs/ARCHITECTURE.md#terminal-queries.

fn fromHandler(h: *ghostty.TerminalStream.Handler) *Terminal {
    const stream: *ghostty.TerminalStream = @fieldParentPtr("handler", h);
    return @fieldParentPtr("stream", stream);
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

    const marker = "ILLOGICAL_SNAPSHOT_MARKER";
    const t = try Terminal.create(gpa, .{
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
        const text = try t.vt.plainString(gpa);
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

    const t = try Terminal.create(gpa, .{
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
