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
    /// Deliver raw PTY bytes. Runs on this terminal's reader thread with
    /// `mutex` held, so it must not block and must not call back into this
    /// terminal.
    ///
    /// Returns false to be unsubscribed. That is the only way out for a
    /// subscriber that cannot keep up: it cannot call `unsubscribe` itself
    /// from in here -- the lock is already held and the list is mid-iteration
    /// -- so it says so and the fan-out drops it. See docs/OPTIMIZATIONS.md F2.
    ///
    /// `terminal` is passed rather than left for the subscriber to recall,
    /// because the subscriber's own idea of which terminal it is attached to
    /// is written by a different thread than the one calling this.
    writeFn: *const fn (ctx: *anyopaque, terminal: session.TerminalId, bytes: []const u8) bool,
    /// The child exited.
    exitFn: *const fn (ctx: *anyopaque, terminal: session.TerminalId, code: i32) void,

    fn write(self: Subscriber, terminal: session.TerminalId, bytes: []const u8) bool {
        return self.writeFn(self.ctx, terminal, bytes);
    }
};

/// Where this terminal's PTY master is being read, and by what.
///
/// The two regimes are not an implementation detail, they are the shape of the
/// server's IO. A hot PTY owns a whole OS thread because that is measurably
/// the fastest way to move bytes; a parked one is a descriptor registration in
/// a poller shared by every other parked PTY, which is ~5-10% slower and costs
/// a rounding error. See docs/ARCHITECTURE.md and docs/OPTIMIZATIONS.md A3.
pub const Regime = enum {
    /// A dedicated OS thread blocked on `read()`.
    hot,
    /// A descriptor in the server's shared poller.
    polled,
    /// Nothing is reading it.
    stopped,
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
/// Monotonic timestamp at which the last subscriber went away, or zero while
/// one is attached. Drives the demotion delay in `park.ptyRegime`. Guarded by
/// `mutex`, like the list it is derived from.
unobserved_since_ns: u64,

subscribers: std.ArrayList(Subscriber) = .empty,

// -- the PTY's IO regime ---------------------------------------------------
//
// See `Regime` and docs/OPTIMIZATIONS.md A3.

/// Guards `regime` and whatever backs it -- the reader thread, or the
/// registration in the shared poller.
///
/// Always taken *outside* `mutex`: leaving the hot regime joins a thread that
/// takes `mutex`, so a caller holding it would wait on itself.
regime_mutex: illogical.thread.Mutex = .{},
regime: Regime = .stopped,
/// The server's shared poller. Null in tests and anywhere else with no server,
/// where a terminal can only ever be hot.
poller: ?*illogical.poller.Poller = null,
thread: ?std.Thread = null,
/// Asks the reader thread to return without reaping the child.
reader_stop: std.atomic.Value(bool) = .init(false),
/// Set by the reader thread as it leaves, so `stopReaderLocked` knows when to
/// stop signalling it.
reader_done: std.atomic.Value(bool) = .init(false),
/// The PTY hung up while polled. `collectExit` reaps it on the next tick.
exit_pending: std.atomic.Value(bool) = .init(false),
/// The exit has been reported. Both regimes can notice a hangup, and
/// subscribers must hear about it exactly once.
exit_reported: std.atomic.Value(bool) = .init(false),
/// Set once the child has been reaped and the exit reported, so the server can
/// retire this terminal. The reader thread cannot destroy its own terminal --
/// that would join itself -- so retiring happens on the maintenance tick.
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
    /// The server's shared poller. Without one this terminal is always hot,
    /// which is what every test that does not care about regimes wants.
    poller: ?*illogical.poller.Poller = null,
};

pub fn create(gpa: Allocator, opts: SpawnOptions) !*Terminal {
    // Here rather than in `Server.init`, because this is the precondition:
    // every terminal has a reader thread that may need interrupting, and
    // nothing guarantees a `Server` was involved in making one. Unhandled,
    // that signal's default disposition ends the process -- which is exactly
    // what it did to five tests that build terminals directly.
    sys.installThreadInterrupt();

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
        // Nobody is watching a terminal that has just been created, and the
        // clock starts now rather than at the first `unsubscribe`.
        .unobserved_since_ns = sys.monotonicNs(),
        .poller = opts.poller,
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
    .device_attributes = deviceAttributesEffect,
    .enquiry = null,
    .size = sizeEffect,
    .xtversion = xtversionEffect,
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
    self.stopIo();
    // Exactly once, and only now that nothing is reading it. This used to be
    // two closes on most paths -- `stop` closed the master to wake the reader,
    // then `deinit` closed it again -- which on a busy daemon is a close of
    // whatever unrelated descriptor had taken the number in between.
    self.pty_pair.deinit();
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

/// Start reading the PTY, hot: a thread of its own, blocked on `read()`.
pub fn start(self: *Terminal) !void {
    self.regime_mutex.lock();
    defer self.regime_mutex.unlock();
    try self.setRegimeLocked(.hot);
}

/// Stop reading the PTY. Leaves the descriptor open for its owner to close.
pub fn stopIo(self: *Terminal) void {
    self.setRegime(.stopped);
}

pub fn currentRegime(self: *Terminal) Regime {
    self.regime_mutex.lock();
    defer self.regime_mutex.unlock();
    return self.regime;
}

/// A client just attached: give this PTY a thread back, now rather than on the
/// next maintenance tick. This is the promotion half of A3's hysteresis, and
/// the reason it is asymmetric -- the side a person can feel is this one.
///
/// Except while parked, where the descriptor belongs in the poller whoever is
/// watching: there is no terminal in memory for a thread to feed, the attach
/// was served from disk, and promoting here would only have the next tick
/// demote it again 250 ms later.
///
/// Must not be called holding `mutex`; see `setRegime`.
pub fn observed(self: *Terminal) void {
    self.mutex.lock();
    const parked = self.residency == .parked;
    self.mutex.unlock();
    if (parked) return;
    self.setRegime(.hot);
}

/// Move this terminal's PTY into `want`.
///
/// **Never call this holding `mutex`.** Leaving the hot regime joins the
/// reader thread, and that thread takes `mutex` on every chunk it reads.
pub fn setRegime(self: *Terminal, want: Regime) void {
    self.regime_mutex.lock();
    defer self.regime_mutex.unlock();
    self.setRegimeLocked(want) catch |err| {
        log.warn("terminal {d}: cannot move pty to {t}: {t}", .{ self.id, want, err });
        // A terminal nobody is reading is a terminal that has silently
        // stopped working, so fall back to the regime that needs nothing but
        // a thread. Costs a thread; the alternative loses the session.
        if (want != .hot) self.setRegimeLocked(.hot) catch {};
    };
}

fn setRegimeLocked(self: *Terminal, want: Regime) !void {
    if (self.regime == want) return;
    // Nothing left to read. Stopping is still allowed -- `destroy` needs it.
    if (want != .stopped and self.finished.load(.acquire)) return;

    // Leave the current regime first: the descriptor belongs to exactly one.
    switch (self.regime) {
        .hot => self.stopReaderLocked(),
        .polled => if (self.poller) |p| p.remove(self.pty_pair.master),
        .stopped => {},
    }
    self.regime = .stopped;

    switch (want) {
        .stopped => {},
        .hot => {
            sys.setNonblock(self.pty_pair.master, false);
            self.reader_stop.store(false, .release);
            self.reader_done.store(false, .release);
            self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
            self.regime = .hot;
        },
        .polled => {
            const p = self.poller orelse return error.NoPoller;
            // Non-blocking, because the thread on the other side of this is
            // shared with every other parked terminal. A wake that turns out
            // to have nothing behind it must not park that thread here.
            sys.setNonblock(self.pty_pair.master, true);
            errdefer sys.setNonblock(self.pty_pair.master, false);
            try p.add(self.pty_pair.master, .{ .ctx = self, .readableFn = pollReadable });
            self.regime = .polled;
        },
    }
}

/// Bring the reader thread out of its blocking `read` and join it.
///
/// It is interrupted, not closed out. Closing is exactly what this must not
/// do -- the descriptor is about to be handed to the poller -- and on macOS
/// `close` does not return while another thread is blocked on the same
/// descriptor anyway, which is issue #28: the daemon hung on shutdown with the
/// two threads waiting on each other inside the kernel.
///
/// Signalled in a loop because delivery only interrupts whatever syscall the
/// thread is in at that instant. A signal that lands while it is writing a
/// query response back to the PTY is absorbed by that write's own retry and
/// the thread goes straight back to sleep. Retrying costs nothing and ends on
/// the first signal that finds it blocked in the read.
fn stopReaderLocked(self: *Terminal) void {
    const t = self.thread orelse return;
    self.reader_stop.store(true, .release);

    // Not bounded, because giving up would be worse than waiting: a thread
    // that happened to be busy when the last signal arrived goes straight back
    // to sleep in `read`, and if nothing wakes it again the join below never
    // returns.
    //
    // Backed off instead. The common case -- a thread already parked in
    // `read` -- ends on the first signal. Past that the thread is doing
    // something else, and something else is exactly what a signal should not
    // be interrupting fifty times a second: a burst of them lands inside the
    // file reads of an unpark, which retry, but need not have been disturbed.
    var attempts: usize = 0;
    while (!self.reader_done.load(.acquire)) : (attempts += 1) {
        sys.interruptThread(t.getHandle());
        sys.sleepNs(if (attempts < interrupt_burst)
            std.time.ns_per_ms
        else
            20 * std.time.ns_per_ms);
    }

    t.join();
    self.thread = null;
}

/// Signals sent a millisecond apart before backing off to 50 Hz. Twenty is far
/// more than a thread blocked in `read` ever needs.
const interrupt_burst = 20;

fn readLoop(self: *Terminal) void {
    defer self.reader_done.store(true, .release);

    var buf: [read_buf_size]u8 = undefined;
    var hung_up = false;
    while (true) {
        const n = sys.readFdOnce(self.pty_pair.master, &buf) catch |err| switch (err) {
            // A signal, which here means one thing: somebody wants this
            // descriptor back. Anything else is the child going away.
            error.Interrupted => {
                if (self.reader_stop.load(.acquire)) break;
                continue;
            },
            // Only reachable if the descriptor was left non-blocking, which
            // it is not in this regime. Treat it as spurious rather than as
            // a hangup.
            error.WouldBlock => continue,
            else => {
                hung_up = true;
                break;
            },
        };
        if (n == 0) {
            hung_up = true;
            break;
        }
        self.ingest(buf[0..n]);
    }

    if (hung_up) self.reap();
}

/// The shared poller has bytes for us.
///
/// One read per wake, not a drain loop: the poller is level-triggered, so
/// whatever is left behind is reported again on the next turn, and draining
/// here would let one busy terminal hold the thread that every other parked
/// terminal is sharing.
fn pollReadable(ctx: *anyopaque) bool {
    const self: *Terminal = @ptrCast(@alignCast(ctx));
    var buf: [read_buf_size]u8 = undefined;
    const n = sys.readFdOnce(self.pty_pair.master, &buf) catch |err| switch (err) {
        error.WouldBlock, error.Interrupted => return true,
        else => {
            self.exit_pending.store(true, .release);
            return false;
        },
    };
    if (n == 0) {
        self.exit_pending.store(true, .release);
        return false;
    }
    self.ingest(buf[0..n]);
    return true;
}

/// Apply one chunk of PTY output and tee it to every subscriber.
///
/// Both under one lock, so that `attach` can insert itself at an exact point
/// in the byte stream and no client can miss or double-apply a chunk.
fn ingest(self: *Terminal, bytes: []const u8) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    // A read is exactly what unparks a terminal. Do it before applying, or
    // the bytes that woke us would be dropped on the floor.
    if (self.residency == .parked) {
        self.unparkLocked() catch |err|
            log.err("terminal {d} failed to unpark: {t}", .{ self.id, err });
    }
    if (self.stream) |*stream| stream.nextSlice(bytes);
    self.last_read_ns = sys.monotonicNs();
    self.fanOutLocked(bytes);
}

/// The exact same bytes, to everyone. No re-encoding. (G2)
///
/// A subscriber that returns false has fallen too far behind to be worth
/// feeding and is dropped here, under the lock that owns the list. This is the
/// server half of docs/OPTIMIZATIONS.md F2: the alternative -- letting the
/// subscriber unsubscribe itself from its own writer thread -- takes this same
/// lock from the far side and deadlocks against an attach in flight.
fn fanOutLocked(self: *Terminal, bytes: []const u8) void {
    var i: usize = 0;
    while (i < self.subscribers.items.len) {
        if (self.subscribers.items[i].write(self.id, bytes)) {
            i += 1;
            continue;
        }
        // Not `swapRemove`: subscribers are fed in order, and reordering them
        // mid-fan-out would skip whoever was moved into this slot.
        _ = self.subscribers.orderedRemove(i);
    }
    self.noteObservationLocked();
}

/// Restart or clear the "nobody is watching" clock. Called under `mutex`
/// wherever the subscriber list changes.
fn noteObservationLocked(self: *Terminal) void {
    const watched = self.subscribers.items.len > 0;
    if (watched) {
        self.unobserved_since_ns = 0;
    } else if (self.unobserved_since_ns == 0) {
        self.unobserved_since_ns = sys.monotonicNs();
    }
}

/// How long nobody has been watching, in nanoseconds. Zero while a client is
/// attached. Drives the demotion delay in `park.ptyRegime`.
pub fn unobservedNs(self: *Terminal) u64 {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.unobserved_since_ns == 0) return 0;
    const now = sys.monotonicNs();
    return if (now > self.unobserved_since_ns) now - self.unobserved_since_ns else 0;
}

/// Wait for the child and report its exit. Blocks, so this only ever runs on
/// the terminal's own reader thread, which is about to end anyway.
fn reap(self: *Terminal) void {
    self.finishExit(sys.wait(self.child));
}

/// Reap a child whose PTY hung up while it was in the shared poller.
///
/// The poller thread cannot do this itself: `waitpid` blocks, and that thread
/// is shared by every parked terminal on the machine, so one child that closed
/// its descriptors without exiting would stop the rest from being watched at
/// all. It flags the hangup instead and the maintenance tick collects it,
/// within a tick. Nobody is watching a polled terminal by definition, so the
/// delay is not something anyone can see.
pub fn collectExit(self: *Terminal) void {
    if (!self.exit_pending.load(.acquire)) return;
    switch (sys.tryWait(self.child)) {
        // Hung up but still alive. Ask again next tick.
        .running => return,
        .exited => |code| {
            self.exit_pending.store(false, .release);
            self.finishExit(code);
        },
        // Already reaped, by a reader thread that had the descriptor before
        // it was polled. `finishExit` is idempotent, so this just tidies up.
        .gone => {
            self.exit_pending.store(false, .release);
            self.finishExit(0);
        },
    }

    self.regime_mutex.lock();
    defer self.regime_mutex.unlock();
    // The poller dropped the registration when the handler returned false.
    if (self.regime == .polled) self.regime = .stopped;
}

/// Record the child's exit and tell everyone watching. At most once: both
/// regimes can notice the same hangup, and a subscriber must not be told twice.
fn finishExit(self: *Terminal, code: i32) void {
    if (self.exit_reported.swap(true, .acq_rel)) return;
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.residency = .exited;
        self.exit_code = code;
        for (self.subscribers.items) |s| s.exitFn(s.ctx, self.id, code);
    }
    // Last, so the server never sees `finished` before the exit has been
    // reported to everyone watching.
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

    // Replace, don't accumulate. A client re-attaching to a terminal it is
    // already subscribed to -- desync recovery, per docs/PROTOCOL.md -- would
    // otherwise appear twice in the fan-out and receive every subsequent PTY
    // byte in two `output` frames, doubling every character it renders.
    self.removeSubscriberLocked(sub.ctx);
    try self.subscribers.append(self.gpa, sub);
    self.noteObservationLocked();
    errdefer self.removeSubscriberLocked(sub.ctx);

    // A parked terminal is served from disk and stays parked (docs/PARKING.md).
    if (self.residency == .parked) {
        try self.streamParkFileLocked(self.store, snapshot_writer);
    } else {
        try self.encodeSnapshotLocked(snapshot_writer);
    }
    // Flush inside the lock. A byte still held here when this returns would
    // reach the client *behind* live output, and a client that applies output
    // before the snapshot it belongs after has a wrong screen.
    try snapshot_writer.flush();
}

pub fn subscribe(self: *Terminal, sub: Subscriber) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.subscribers.append(self.gpa, sub);
    self.noteObservationLocked();
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
    self.noteObservationLocked();
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
        .regime = @tagName(self.currentRegime()),
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

/// Answer device attribute queries (CSI c, CSI > c, CSI = c).
///
/// Leaving this null does not merely omit a nicety: libghostty-vt drops the
/// query on the floor and the child waits. Neovim ends its exit sequence with
/// a DA1 request used as a sentinel -- it restores the terminal modes, asks
/// who we are, and only leaves the alternate screen once we answer. Unanswered,
/// every `:qa` paid Neovim's full one-second timeout before the shell came
/// back. Measured on this machine: 1.11s unanswered, 0.10s answered.
///
/// What we claim is what the daemon's VT actually is: a VT220 with color. Not
/// clipboard access (feature 52), which Ghostty advertises and we cannot honour
/// -- `clipboard_read` and `clipboard_write` above are null, so a program that
/// believed us would wait on a reply that never comes. Exactly the bug this
/// function exists to fix.
fn deviceAttributesEffect(
    _: *ghostty.TerminalStream.Handler,
) DeviceAttributes {
    return .{
        .primary = .{
            // `level_2` is the VT200 series; `.vt220` is a lowercase alias for
            // it, and an alias is a declaration, not a field, so it cannot be
            // written as an enum literal here.
            .conformance_level = .level_2,
            .features = &.{.ansi_color},
        },
    };
}

/// libghostty-vt's public Zig API re-exports the device *status* namespace but
/// not `device_attributes`, so the response type has no name we can spell.
/// Recover it from the signature of the effect that returns it.
const DeviceAttributes = @typeInfo(@typeInfo(@typeInfo(
    @FieldType(ghostty.TerminalStream.Handler.Effects, "device_attributes"),
).optional.child).pointer.child).@"fn".return_type.?;

/// Answer XTVERSION (CSI > q) with our own name.
///
/// Unlike the device attributes above, libghostty-vt always replies here; with
/// no effect installed it reports itself as "libghostty". That is the wrong
/// name for a program probing what it is talking to -- the child's environment
/// already says `TERM_PROGRAM=illogical`, and the two should agree.
fn xtversionEffect(_: *ghostty.TerminalStream.Handler) []const u8 {
    return "illogical " ++ illogical.version;
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

/// A subscriber that counts chunks. One call means one PTY read reached the
/// fan-out, which is how these tests tell "something is reading this
/// descriptor" from "something is registered to".
const Ticks = struct {
    mutex: illogical.thread.Mutex = .{},
    n: usize = 0,

    fn subscriber(self: *Ticks) Subscriber {
        return .{ .ctx = self, .writeFn = write, .exitFn = exited };
    }

    fn write(ctx: *anyopaque, _: session.TerminalId, _: []const u8) bool {
        const self: *Ticks = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.n += 1;
        return true;
    }

    fn exited(_: *anyopaque, _: session.TerminalId, _: i32) void {}

    fn count(self: *Ticks) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.n;
    }

    /// Wait for the count to move past `from`. False on timeout.
    fn advancedPast(self: *Ticks, from: usize) bool {
        var waited: usize = 0;
        while (waited < 5000) : (waited += 10) {
            if (self.count() > from) return true;
            sys.sleepNs(10 * std.time.ns_per_ms);
        }
        return false;
    }
};

/// A child that keeps producing output forever, slowly enough not to swamp
/// anything. `stdbuf` is not available everywhere, so the newline does the
/// flushing.
const ticker_argv = [_][]const u8{
    "/bin/sh",                                                                   "-c",
    "i=0; while :; do i=$((i+1)); printf 'TICK %d\\n' \"$i\"; sleep 0.05; done",
};

test "a pty migrates between a dedicated thread and the shared poller" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var poller: illogical.poller.Poller = try .init(gpa);
    defer poller.deinit();
    try poller.start();

    const t = try Terminal.create(gpa, .{
        .io = threaded.io(),
        .store = .{ .root = "/tmp/illogical-unused" },
        .id = 1,
        .session_id = 1,
        .name = "migrate",
        .argv = &ticker_argv,
        .poller = &poller,
    });
    defer t.destroy();
    defer t.hangup();

    var ticks: Ticks = .{};
    try t.subscribe(ticks.subscriber());
    try t.start();

    // Hot: a thread of its own, nothing registered with the poller.
    try testing.expectEqual(Regime.hot, t.currentRegime());
    try testing.expectEqual(@as(usize, 0), poller.count());
    try testing.expect(ticks.advancedPast(0));

    // Demote. The reader thread is blocked in `read()` at this moment, so this
    // only returns if the interrupt reached it -- and the descriptor must
    // survive, because closing it is how the old code woke the thread.
    const before_polled = ticks.count();
    t.setRegime(.polled);
    try testing.expectEqual(Regime.polled, t.currentRegime());
    try testing.expectEqual(@as(usize, 1), poller.count());

    // Still being read, now by the shared thread.
    try testing.expect(ticks.advancedPast(before_polled));

    // And back. This is the promotion an attach triggers.
    const before_hot = ticks.count();
    t.setRegime(.hot);
    try testing.expectEqual(Regime.hot, t.currentRegime());
    try testing.expectEqual(@as(usize, 0), poller.count());
    try testing.expect(ticks.advancedPast(before_hot));

    // The terminal state kept up across both migrations, which is the part
    // that would break if a chunk were dropped at a handover.
    const text = try t.plainText(gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "TICK ") != null);
}

test "many polled terminals share one thread" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var poller: illogical.poller.Poller = try .init(gpa);
    defer poller.deinit();
    try poller.start();

    const count = 8;
    var terminals: [count]*Terminal = undefined;
    var ticks: [count]Ticks = undefined;
    for (&terminals, 0..) |*slot, i| {
        slot.* = try Terminal.create(gpa, .{
            .io = threaded.io(),
            .store = .{ .root = "/tmp/illogical-unused" },
            .id = @intCast(i + 1),
            .session_id = 1,
            .name = "fleet",
            .argv = &ticker_argv,
            .poller = &poller,
        });
        ticks[i] = .{};
        try slot.*.subscribe(ticks[i].subscriber());
        try slot.*.start();
    }
    defer for (terminals) |t| {
        t.hangup();
        t.destroy();
    };

    for (terminals) |t| t.setRegime(.polled);

    // The count that must not track terminal count is threads; the count that
    // does is registrations. That is the trade this whole change makes.
    try testing.expectEqual(@as(usize, count), poller.count());
    for (terminals) |t| try testing.expectEqual(Regime.polled, t.currentRegime());

    // All of them still being read, by that one thread.
    for (&ticks) |*tick| try testing.expect(tick.advancedPast(0));
}

/// Runs `destroy` on a thread of its own so that a deadlock inside it fails
/// the test instead of hanging the suite forever.
const Destroyer = struct {
    terminal: *Terminal,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Destroyer) void {
        self.terminal.destroy();
        self.done.store(true, .release);
    }

    fn finishesWithin(self: *Destroyer, ms: usize) !bool {
        var t = try std.Thread.spawn(.{}, run, .{self});
        var waited: usize = 0;
        while (waited < ms) : (waited += 10) {
            if (self.done.load(.acquire)) {
                t.join();
                return true;
            }
            sys.sleepNs(10 * std.time.ns_per_ms);
        }
        // Deliberately not joined: the point is that it is stuck.
        t.detach();
        return false;
    }
};

test "migrating mid-stream does not lose a byte" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var poller: illogical.poller.Poller = try .init(gpa);
    defer poller.deinit();
    try poller.start();

    const lines = 3000;
    const t = try Terminal.create(gpa, .{
        .io = threaded.io(),
        .store = .{ .root = "/tmp/illogical-unused" },
        .id = 1,
        .session_id = 1,
        .name = "handover",
        .argv = &.{
            "/bin/sh",                                                      "-c",
            "awk 'BEGIN{for(i=0;i<3000;i++) print \"MARK \" i}'; sleep 30",
        },
        .poller = &poller,
    });
    defer t.destroy();
    defer t.hangup();

    var sink: Recorder = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);
    try t.subscribe(sink.subscriber());
    try t.start();

    // Flip regimes repeatedly while the child is still writing. Every switch
    // interrupts a reader thread that may be mid-stream, or hands a descriptor
    // to the poller with bytes already waiting behind it.
    for (0..6) |i| {
        t.setRegime(if (i % 2 == 0) .polled else .hot);
        sys.sleepNs(15 * std.time.ns_per_ms);
    }

    var waited: usize = 0;
    while (waited < 10_000) : (waited += 10) {
        if (sink.contains("MARK 2999\r")) break;
        sys.sleepNs(10 * std.time.ns_per_ms);
    } else return error.StreamNeverFinished;

    const got = try sink.snapshot(gpa);
    defer gpa.free(got);

    // Every line, in order. The trailing `\r` rather than `\r\n` because a
    // macOS pty whose output queue fills mid-write restarts its `\n` -> `\r\n`
    // expansion and emits `\r\r\n`; the count of carriage returns is the tty's
    // business, but no line may be missing or out of order.
    var searched: usize = 0;
    var needle_buf: [32]u8 = undefined;
    for (0..lines) |i| {
        const needle = try std.fmt.bufPrint(&needle_buf, "MARK {d}\r", .{i});
        const at = std.mem.indexOfPos(u8, got, searched, needle) orelse
            return error.LineLostAcrossMigration;
        searched = at + needle.len;
    }
}

/// Accumulates everything fanned out, for tests that care about the stream
/// rather than about how often it arrived.
const Recorder = struct {
    gpa: Allocator,
    mutex: illogical.thread.Mutex = .{},
    bytes: std.ArrayList(u8) = .empty,

    fn subscriber(self: *Recorder) Subscriber {
        return .{ .ctx = self, .writeFn = write, .exitFn = exited };
    }

    fn write(ctx: *anyopaque, _: session.TerminalId, bytes: []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.bytes.appendSlice(self.gpa, bytes) catch return false;
        return true;
    }

    fn exited(_: *anyopaque, _: session.TerminalId, _: i32) void {}

    fn contains(self: *Recorder, needle: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return std.mem.indexOf(u8, self.bytes.items, needle) != null;
    }

    fn snapshot(self: *Recorder, gpa: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return gpa.dupe(u8, self.bytes.items);
    }
};

test "a terminal with a quiet child tears down without deadlocking (#28)" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    // A shell sitting at a prompt: alive, and producing nothing. Its reader
    // thread is parked in `read()` and will stay there.
    const t = try Terminal.create(gpa, .{
        .io = threaded.io(),
        .store = .{ .root = "/tmp/illogical-unused" },
        .id = 1,
        .session_id = 1,
        .name = "quiet",
        .argv = &.{ "/bin/sh", "-c", "sleep 60" },
    });
    try t.start();
    // Let the reader thread reach the read it is going to sit in.
    sys.sleepNs(100 * std.time.ns_per_ms);

    // This used to hang forever. `stop` closed the pty master to wake the
    // reader, and on macOS `close` does not return while another thread holds
    // that descriptor inside a blocking `read` -- so the two waited on each
    // other in the kernel and `illogicald` had to be killed with SIGKILL.
    // Interrupting the read instead is what makes this return.
    var destroyer: Destroyer = .{ .terminal = t };
    // No `hangup` first, on purpose: hanging the child up is what used to hide
    // this, because the child exiting ended the read and let the close finish.
    try testing.expect(try destroyer.finishesWithin(5000));
}

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

test "the device attributes response encodes as a VT220 with color" {
    const testing = std.testing;

    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try deviceAttributesEffect(undefined).encode(.primary, &writer);

    // Not `;52c`: advertising clipboard access we do not implement would
    // strand the next program on a reply that never comes.
    try testing.expectEqualStrings("\x1b[?62;22c", buf[0..writer.end]);
}

test "the secondary and tertiary responses are pinned too" {
    const testing = std.testing;

    // One effect answers all three request types, and everything we leave
    // unset takes libghostty-vt's defaults -- so DA2 and DA3 are answers this
    // daemon now gives and previously did not. A PR about unanswered queries
    // should not leave its own new answers unpinned.
    var buf: [64]u8 = undefined;

    var secondary: std.Io.Writer = .fixed(&buf);
    try deviceAttributesEffect(undefined).encode(.secondary, &secondary);
    // VT220, firmware 0, no ROM cartridge. Ghostty reports firmware 10 here;
    // the field is meaningless for an emulator and nothing reads it.
    try testing.expectEqualStrings("\x1b[>1;0;0c", buf[0..secondary.end]);

    var tertiary: std.Io.Writer = .fixed(&buf);
    try deviceAttributesEffect(undefined).encode(.tertiary, &tertiary);
    // DECRPTUI with a zero unit ID. Ghostty declines to answer DA3 at all;
    // answering costs nothing and spares the caller another timeout.
    try testing.expectEqualStrings("\x1bP!|00000000\x1b\\", buf[0..tertiary.end]);
}

test "a device attributes query is answered back through the pty" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    // Ask for DA1, read back exactly the 9 bytes of the reply, and print them
    // somewhere `plainText` can see. Raw mode because the reply carries no
    // newline, and a canonical-mode read would block waiting for one.
    const script =
        \\stty raw -echo
        \\printf '\033[c'
        \\R=$(dd bs=1 count=9 2>/dev/null | od -An -c | tr -d ' \n')
        \\printf 'DA1<%s>' "$R"
        \\sleep 10
    ;
    const t = try Terminal.create(gpa, .{
        .io = threaded.io(),
        .store = .{ .root = "/tmp/illogical-unused" },
        .id = 1,
        .session_id = 1,
        .name = "da1",
        .argv = &.{ "/bin/sh", "-c", script },
        .cols = 80,
        .rows = 24,
    });
    defer t.destroy();
    // Runs before `destroy` (defers unwind last-in-first-out), and has to:
    // issue #28 means `stop()` blocks in `close()` on the pty master for as
    // long as the reader thread is blocked in `read()` on it, and this child is
    // quiet on both paths -- sitting in `sleep 10` when the test passes, and
    // stuck forever in `dd` when it fails. SIGHUP ends the child either way, so
    // a regression fails here in five seconds rather than hanging the suite.
    defer t.hangup();
    try t.start();

    // Unanswered, the child stays blocked in `dd` and this loop runs out --
    // which is exactly the failure this test is here to catch.
    var waited: usize = 0;
    while (waited < 5000) : (waited += 10) {
        const text = t.plainText(gpa) catch {
            sys.sleepNs(10 * std.time.ns_per_ms);
            continue;
        };
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, "DA1<033[?62;22c>") != null) break;
        sys.sleepNs(10 * std.time.ns_per_ms);
    } else return error.DeviceAttributesNeverAnswered;
}

test "xtversion reports illogical, not the library underneath" {
    try std.testing.expectEqualStrings(
        "illogical " ++ illogical.version,
        xtversionEffect(undefined),
    );
}
