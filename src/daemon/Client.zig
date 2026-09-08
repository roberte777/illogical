//! One client connection.
//!
//! Two threads. The *reader* reads frames off the socket and dispatches them.
//! The *writer* drains a bounded queue of already-framed bytes to the socket.
//! Nothing else ever touches the socket.
//!
//! The writer exists because of where output comes from. Fan-out runs on a
//! terminal's reader thread, under that terminal's lock, and a `write` to a
//! client that has stopped reading blocks until the kernel buffer drains. One
//! such client used to stall the terminal itself -- its PTY, its state, and
//! every other client attached to it. So `onOutput` copies into the queue and
//! returns, and if the queue is full the client is dropped back to a fresh
//! attach rather than served an unbounded replay (docs/OPTIMIZATIONS.md F2).
//!
//! **Lock order: a terminal's lock, then this client's queue lock.** Fan-out
//! and `attach` both hold a terminal lock while enqueuing. Nothing may take a
//! terminal lock while holding `queue_mutex` -- which is why an overflowing
//! subscriber is pruned by the terminal itself, from inside its own fan-out
//! loop, rather than by the writer thread.

const Client = @This();

const std = @import("std");
const builtin = @import("builtin");
const sys = illogical.sys;
const Allocator = std.mem.Allocator;
const ghostty = @import("ghostty-vt");
const illogical = @import("illogical");
const protocol = illogical.protocol;
const session = illogical.session;
const Server = @import("Server.zig");
const Terminal = @import("Terminal.zig");

const log = std.log.scoped(.client);

/// Default bound on a client's queued, not-yet-written output.
///
/// Sixteen PTY reads' worth. Big enough that an ordinary scheduling hiccup on
/// the client is absorbed rather than punished, small enough that a thousand
/// stalled clients cannot cost more than the machine has. A client that falls
/// this far behind is better served by a new snapshot than by a long replay --
/// which is the whole argument of docs/OPTIMIZATIONS.md F2.
pub const default_queue_bytes: usize = 1 << 20;

server: *Server,
fd: sys.fd_t,
gpa: Allocator,

attached: std.ArrayList(session.TerminalId) = .empty,

// -- the output queue ------------------------------------------------------

/// Guards everything in this block. Never held across a socket write, and
/// never held while taking a terminal's lock.
queue_mutex: illogical.thread.Mutex = .{},
/// Framed bytes waiting to go out. Producers append here.
queue: std.ArrayList(u8) = .empty,
/// The writer swaps `queue` into this and writes it with the lock dropped, so
/// producers keep filling one buffer while the other is in a syscall. The two
/// trade places rather than reallocating.
outgoing: std.ArrayList(u8) = .empty,
/// Bound on `queue`. Set from `Server.client_queue_bytes`.
queue_cap: usize,
/// Signalled when `queue` gains bytes, or when the writer should give up.
queue_ready: illogical.thread.Condition = .{},
/// Signalled when the writer has taken the queue, so a producer waiting for
/// room can try again.
queue_drained: illogical.thread.Condition = .{},
/// Set when the queue overflowed. The client has missed output and has been
/// unsubscribed; it is told so and must re-attach.
desynced: bool = false,
/// Set by `parkBuffers`, acted on by the writer thread when it next finds the
/// queue empty. See "buffer parking" below.
park_requested: bool = false,

// -- the read path ---------------------------------------------------------

/// Guards `read_payload`, and only that. Held by the reader from the moment a
/// frame header arrives until that frame has been dispatched -- so a client
/// blocked waiting for its next frame, which is the idle state, holds nothing.
read_mutex: illogical.thread.Mutex = .{},
/// The frame body being read. A field rather than a local so that it can be
/// freed while the client is idle; it grows to the largest frame the client
/// ever sent and then keeps that memory forever.
read_payload: std.ArrayList(u8) = .empty,

/// Monotonic nanoseconds at the last frame in or out. Drives buffer parking.
last_activity_ns: std.atomic.Value(u64),

reader: ?std.Thread = null,
writer: ?std.Thread = null,
/// The socket is still usable. Cleared once either end has gone away.
alive: std.atomic.Value(bool) = .init(true),
/// The writer should stop once it has drained what it has.
draining: std.atomic.Value(bool) = .init(false),
/// The reader thread has left `run`. The maintenance tick retires the client;
/// the thread cannot destroy itself, because destroying joins it.
finished: std.atomic.Value(bool) = .init(false),

pub fn create(server: *Server, fd: sys.fd_t) !*Client {
    const self = try server.gpa.create(Client);
    self.* = .{
        .server = server,
        .fd = fd,
        .gpa = server.gpa,
        .queue_cap = server.client_queue_bytes,
        .last_activity_ns = .init(sys.monotonicNs()),
    };
    return self;
}

/// Tear the connection down and free it. Both threads are joined, so no part
/// of this client is in use when it returns.
///
/// The caller must not hold `Server.clients_mutex`: the reader thread reaches
/// into the server as it unwinds.
pub fn destroy(self: *Client) void {
    self.detachAll();
    // Before the joins. A reader blocked in `read` and a writer blocked in
    // `write` both need the socket broken under them to come back, and
    // `close` would not do it -- see `sys.shutdownFd`.
    self.alive.store(false, .release);
    sys.shutdownFd(self.fd);

    if (self.reader) |t| {
        t.join();
        self.reader = null;
    }
    self.stopWriter();

    sys.closeFd(self.fd);
    self.queue.deinit(self.gpa);
    self.outgoing.deinit(self.gpa);
    self.read_payload.deinit(self.gpa);
    self.attached.deinit(self.gpa);
    self.gpa.destroy(self);
}

pub fn start(self: *Client) !void {
    try self.startWriter();
    errdefer self.stopWriter();
    self.reader = try std.Thread.spawn(.{ .stack_size = Terminal.thread_stack_size }, run, .{self});
}

fn startWriter(self: *Client) !void {
    self.writer = try std.Thread.spawn(.{ .stack_size = Terminal.thread_stack_size }, writeLoop, .{self});
}

/// Let the writer finish what it has, then join it.
///
/// `draining` rather than `alive`: on an orderly disconnect the last `exited`
/// frame is usually still queued, and it is worth the microsecond. When the
/// socket is already broken `writeAll` fails and the writer leaves anyway.
fn stopWriter(self: *Client) void {
    {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        self.draining.store(true, .release);
        self.queue_ready.signal();
        self.queue_drained.broadcast();
    }
    if (self.writer) |t| {
        t.join();
        self.writer = null;
    }
}

fn run(self: *Client) void {
    defer {
        // Unsubscribe before anything else: from here on no terminal holds a
        // pointer to this client, so the retirement below cannot race a
        // fan-out.
        self.detachAll();
        // Not `stopWriter`: joining the writer from here would be fine, but
        // the flush is worth nothing if the far end has already gone, and
        // `destroy` joins it on the maintenance tick either way.
        self.draining.store(true, .release);
        self.wakeQueue();
        self.finished.store(true, .release);
    }

    var header_buf: [protocol.header_len]u8 = undefined;

    while (self.alive.load(.acquire)) {
        // Outside `read_mutex`: this is where an idle client waits, sometimes
        // for hours, and holding the lock here would mean its read buffer
        // could never be parked.
        self.readExact(&header_buf) catch break;
        const header = protocol.Header.decode(&header_buf) catch |err| {
            log.warn("bad frame header: {t}", .{err});
            break;
        };
        self.touch();

        self.read_mutex.lock();
        defer self.read_mutex.unlock();

        self.read_payload.clearRetainingCapacity();
        self.read_payload.resize(self.gpa, header.len) catch break;
        if (header.len > 0) self.readExact(self.read_payload.items) catch break;

        self.dispatch(header, self.read_payload.items) catch |err| switch (err) {
            // The queue overflowed underneath this frame. The client has
            // already been sent `desync` and unsubscribed; another `err` on
            // top of it would say nothing new.
            error.ClientBehind => continue,
            // A client whose protocol version we refused. `stopWriter` first,
            // so the `err` frame that is still queued reaches the wire -- the
            // writer loop returns only on an empty queue -- and then break
            // both directions, which is what turns "we stopped answering"
            // into an end-of-file the client sees now rather than at the next
            // maintenance tick. `destroy` finds `writer == null` later and its
            // own `shutdownFd` returns ENOTCONN; both are harmless.
            error.ProtocolRefused => {
                self.stopWriter();
                sys.shutdownFd(self.fd);
                break;
            },
            else => {
                log.warn("frame {t} failed: {t}", .{ header.type, err });
                self.sendError(header.session, .unknown, @errorName(err)) catch break;
            },
        };
    }
}

/// Note that this client is not idle. See "buffer parking".
fn touch(self: *Client) void {
    self.last_activity_ns.store(sys.monotonicNs(), .release);
}

fn readExact(self: *Client, buf: []u8) !void {
    try sys.readAll(self.fd, buf);
}

fn dispatch(self: *Client, header: protocol.Header, payload: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (header.type) {
        .hello => {
            const req = try protocol.body.decode(protocol.body.Hello, arena, payload);
            defer req.deinit();
            if (req.value.version != protocol.version) {
                try self.sendError(
                    protocol.control_session,
                    .version_mismatch,
                    "unsupported protocol version",
                );
                // And nothing else on this connection, ever. Refusing the
                // `hello` and then carrying on is not a refusal: a client
                // sends `hello` and `list` back to back, so the daemon
                // answered the `err` and then the `session_list` behind it,
                // and the app -- which reads a `session_list` as "connected"
                // -- attached 55 ms after being told its protocol was
                // unsupported. Whatever the version difference actually is
                // then surfaces as garbage or a hang somewhere downstream,
                // instead of as the sentence this refusal exists to produce.
                return error.ProtocolRefused;
            }
            const bytes = try protocol.body.encode(arena, protocol.body.Welcome{
                .server = illogical.version,
            });
            try self.send(.welcome, protocol.control_session, bytes);
        },

        .list => {
            const list = try self.server.listInto(arena);
            const bytes = try protocol.body.encode(arena, list);
            try self.send(.session_list, protocol.control_session, bytes);
        },

        .create => {
            const req = try protocol.body.decode(protocol.body.Create, arena, payload);
            defer req.deinit();
            const result = self.server.createTerminal(req.value) catch |err| switch (err) {
                // The *session* name, not the terminal's: only the session's
                // reaches the registry and the park store, and only it is
                // validated. Mapped here rather than left to the generic
                // handler so a client is told `invalid_name` and the rule,
                // exactly as it would be for a refused rename.
                error.NameEmpty, error.NameTooLong, error.NameInvalidChar => return self.sendError(
                    header.session,
                    .invalid_name,
                    "invalid session name (1-64 characters of A-Za-z0-9._-)",
                ),
                else => return err,
            };
            const bytes = try protocol.body.encode(arena, protocol.body.Created{
                .terminal = result.terminal,
                .session = result.session,
            });
            try self.send(.created, result.terminal, bytes);
            // Everyone else's tab strip is now stale.
            self.server.notifySessionsChanged();
        },

        .attach => {
            const req = try protocol.body.decode(protocol.body.Attach, arena, payload);
            defer req.deinit();
            // Everything the client missed is about to be in the snapshot it
            // asked for, so whatever it was told to recover from is over.
            self.clearDesync();
            try self.attach(header.session, req.value);
        },

        .detach => {
            if (self.server.terminal(header.session)) |t| t.unsubscribe(self);
            self.removeAttached(header.session);
        },

        .input => {
            const t = self.server.terminal(header.session) orelse
                return self.sendError(header.session, .no_such_session, "no such terminal");
            try t.writeInput(payload);
        },

        .resize => {
            const req = try protocol.body.decode(protocol.body.Resize, arena, payload);
            defer req.deinit();
            const t = self.server.terminal(header.session) orelse
                return self.sendError(header.session, .no_such_session, "no such terminal");
            try t.resize(req.value.cols, req.value.rows, .{
                .width = req.value.cell_width,
                .height = req.value.cell_height,
            });
        },

        .kill => {
            // An empty payload means "close it": fall back to the struct's
            // own default rather than a second, different literal. This
            // silently sent SIGTERM -- which an interactive shell ignores --
            // so closing a tab did nothing.
            const default: protocol.body.Kill = .{};
            const req = protocol.body.decode(protocol.body.Kill, arena, payload) catch null;
            defer if (req) |r| r.deinit();
            const signal = if (req) |r| r.value.signal else default.signal;
            try self.server.killTerminal(header.session, signal);
        },

        .peek => {
            const t = self.server.terminal(header.session) orelse
                return self.sendError(header.session, .no_such_session, "no such terminal");
            const text = t.plainText(arena) catch |err| switch (err) {
                // Peeking must not wake a parked terminal; that would defeat
                // the point. Say so instead.
                error.TerminalParked => {
                    try self.send(.screen, header.session, "<parked>\n");
                    return;
                },
                else => return err,
            };
            try self.send(.screen, header.session, text);
        },

        // Session-scoped, so the id is in the body: the header's u64 addresses
        // a terminal and these two do not name one. Both are sent on the
        // control channel; a refusal comes back on it.
        .rename_session => {
            const req = try protocol.body.decode(protocol.body.RenameSession, arena, payload);
            defer req.deinit();
            self.server.renameSession(req.value.session, req.value.name) catch |err| switch (err) {
                error.NoSuchSession => return self.sendError(
                    header.session,
                    .no_such_session,
                    "no such session",
                ),
                error.NameEmpty, error.NameTooLong, error.NameInvalidChar => return self.sendError(
                    header.session,
                    .invalid_name,
                    "invalid session name",
                ),
                error.NameInUse => return self.sendError(
                    header.session,
                    .name_in_use,
                    "a session with that name already exists",
                ),
                else => return err,
            };
            // The reply half of the request `sessions_changed` has always
            // documented itself as covering. Everyone re-lists, including us.
            self.server.notifySessionsChanged();
        },

        .delete_session => {
            const req = try protocol.body.decode(protocol.body.DeleteSession, arena, payload);
            defer req.deinit();
            const mode: Server.DeleteMode =
                if (req.value.only_if_empty) .only_if_empty else .cascade;
            self.server.deleteSession(req.value.session, mode) catch |err| switch (err) {
                error.NoSuchSession => return self.sendError(
                    header.session,
                    .no_such_session,
                    "no such session",
                ),
                error.SessionBusy => return self.sendError(
                    header.session,
                    .session_busy,
                    "session is not empty",
                ),
                else => return err,
            };
            // No broadcast here, deliberately: nothing has left the list yet.
            // The terminals were hung up, and `retireExited` announces it once
            // -- on the tick that retires the last of them and drops the
            // emptied session together.
        },

        .ping => try self.send(.pong, header.session, payload),

        else => return error.UnexpectedFrame,
    }
}

// -- attach ----------------------------------------------------------------

/// Finds the end of a snapshot's READY marker in a byte stream, by record
/// framing alone.
///
/// A snapshot is a ten-byte envelope followed by records, each a ten-byte
/// header — tag, payload length, CRC32C — and its payload. READY is an empty
/// record separating the renderable screen from history, so locating it needs
/// no payload decoding and buffers nothing beyond one header. See
/// `vendor/ghostty/src/terminal/snapshot/main.zig`.
///
/// This is what lets `snapshot_ready` go out mid-encode. Without it the marker
/// carries no information: the whole snapshot, history included, is already on
/// the wire before the client is told it can paint, and attach latency grows
/// linearly with scrollback.
const ReadyScanner = struct {
    const header_len = ghostty.snapshot.record.Header.len;
    const ready_tag = @intFromEnum(ghostty.snapshot.record.Tag.ready);

    phase: Phase = .envelope,
    /// Bytes still to skip: the rest of the envelope, or of the current payload.
    remaining: usize = ghostty.snapshot.envelope.encoded_len,
    /// Header bytes buffered so far, while `phase` is `.header`.
    have: usize = 0,
    header: [header_len]u8 = undefined,
    /// Whether the record currently being skipped is READY.
    is_ready: bool = false,

    const Phase = enum { envelope, header, payload, done };

    /// Consume `bytes`, returning the offset just past the READY record if it
    /// ends inside this slice. Returns null before that, and forever after.
    fn scan(self: *ReadyScanner, bytes: []const u8) ?usize {
        var i: usize = 0;
        while (i < bytes.len) {
            switch (self.phase) {
                .done => return null,

                // Neither carries information we need, so both are skipped by
                // length. `remaining` is never zero here: a zero-length payload
                // is completed below, where its header is decoded.
                .envelope, .payload => {
                    const take = @min(self.remaining, bytes.len - i);
                    i += take;
                    self.remaining -= take;
                    if (self.remaining > 0) continue;
                    if (self.phase == .payload and self.is_ready) {
                        self.phase = .done;
                        return i;
                    }
                    self.expectHeader();
                },

                .header => {
                    const take = @min(header_len - self.have, bytes.len - i);
                    @memcpy(self.header[self.have..][0..take], bytes[i..][0..take]);
                    self.have += take;
                    i += take;
                    // Ran out of bytes mid-header; resume on the next slice.
                    if (self.have < header_len) break;

                    const tag = std.mem.readInt(u16, self.header[0..2], .little);
                    self.is_ready = tag == ready_tag;
                    self.remaining = std.mem.readInt(u32, self.header[2..6], .little);
                    self.phase = .payload;
                    if (self.remaining > 0) continue;
                    // READY is an empty record, so it ends with its header.
                    if (self.is_ready) {
                        self.phase = .done;
                        return i;
                    }
                    self.expectHeader();
                },
            }
        }
        return null;
    }

    fn expectHeader(self: *ReadyScanner) void {
        self.phase = .header;
        self.have = 0;
    }
};

/// Frames snapshot bytes as they are produced, so the client can start
/// decoding before the encode finishes. See docs/PROTOCOL.md.
///
/// The writer is unbuffered because `snapshot_ready` is latency, not framing:
/// a buffer would hold the READY marker until it filled, which is the number
/// the M2 gate measures. The scanner does not need it — it is built to find
/// the marker across arbitrary slice boundaries and `sendBytes` splits within
/// a slice.
///
/// The cost is frame count. `record.Writer.finish` emits each record as two
/// writes, a ten-byte header and its payload, so every snapshot record becomes
/// two `snapshot_chunk` frames — one of them ten bytes of payload behind a
/// thirteen-byte header. Bounded by record count, and worth revisiting if the
/// SSH transport makes per-frame overhead matter.
const SnapshotChunker = struct {
    client: *Client,
    terminal_id: session.TerminalId,
    interface: std.Io.Writer,
    scanner: ReadyScanner = .{},
    /// Whether `snapshot_ready` has gone out yet.
    sent_ready: bool = false,

    fn init(client: *Client, terminal_id: session.TerminalId) SnapshotChunker {
        return .{
            .client = client,
            .terminal_id = terminal_id,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    /// Frame one run of snapshot bytes, splitting it at READY if the marker
    /// ends inside it.
    fn sendBytes(self: *SnapshotChunker, bytes: []const u8) !void {
        const split = self.scanner.scan(bytes) orelse
            return self.client.send(.snapshot_chunk, self.terminal_id, bytes);

        if (split > 0) {
            try self.client.send(.snapshot_chunk, self.terminal_id, bytes[0..split]);
        }
        try self.client.send(.snapshot_ready, self.terminal_id, &.{});
        self.sent_ready = true;
        if (split < bytes.len) {
            try self.client.send(.snapshot_chunk, self.terminal_id, bytes[split..]);
        }
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SnapshotChunker = @fieldParentPtr("interface", w);
        var written: usize = 0;
        for (data, 0..) |slice, i| {
            const times = if (i == data.len - 1) splat else 1;
            for (0..times) |_| {
                if (slice.len == 0) continue;
                self.sendBytes(slice) catch return error.WriteFailed;
                written += slice.len;
            }
        }
        return written;
    }
};

fn attach(self: *Client, id: session.TerminalId, req: protocol.body.Attach) !void {
    const t = self.server.terminal(id) orelse
        return self.sendError(id, .no_such_session, "no such terminal");

    if (req.cols > 0 and req.rows > 0) try t.resize(req.cols, req.rows, .{
        .width = req.cell_width,
        .height = req.cell_height,
    });

    const begin = try protocol.body.encode(self.gpa, protocol.body.SnapshotBegin{});
    defer self.gpa.free(begin);
    try self.send(.snapshot_begin, id, begin);

    var chunker = SnapshotChunker.init(self, id);
    // `Terminal.attach` drops any subscriber we already had before installing
    // the new one, so from here on a failure means we are subscribed to
    // nothing -- including on a re-attach, where we *were* subscribed on the
    // way in. This errdefer is above the call for that reason: it has to undo
    // the record of an attachment that no longer exists.
    errdefer self.removeAttached(id);
    // Subscribe and snapshot under the terminal's lock, so the client gets
    // every byte after the snapshot and none from before it.
    try t.attach(.{
        .ctx = self,
        .writeFn = onOutput,
        .exitFn = onExit,
    }, &chunker.interface);
    errdefer t.unsubscribe(self);

    // Record it before the frames below, because `detachAll` only knows about
    // ids in `attached`: a client that closes its socket during them makes
    // those `send`s fail, and without this the subscriber outlives the
    // connection -- fanned out to on every PTY read for the life of the
    // daemon, and counted forever by `illogical list`.
    //
    // Only this thread reads `attached` now. It used to be read from the
    // terminal's reader thread too, to work out which terminal an `output`
    // frame belonged to, which meant output produced between `t.attach`
    // returning and this append was tagged with the control session. The
    // terminal passes its own id to `onOutput` instead, so the list is no
    // longer part of the fan-out path and that window is gone.
    if (!self.isAttached(id)) try self.attached.append(self.gpa, id);

    // Somebody is judging this terminal now, so give its PTY a thread back --
    // immediately, not on the next maintenance tick. Outside the terminal's
    // lock, which `t.attach` has already released: changing regime joins a
    // thread that wants it.
    t.observed();

    // The chunker sends `snapshot_ready` the moment the encoder passes READY.
    // If the scan never found it — a snapshot format change, a truncated park
    // file — send it here, so the client paints a blank screen and takes live
    // output rather than waiting forever.
    if (!chunker.sent_ready) try self.send(.snapshot_ready, id, &.{});
    try self.send(.snapshot_end, id, &.{});
}

/// Fan-out, on a terminal's reader thread and under that terminal's lock.
///
/// Returns false to be dropped from the terminal's subscriber list. That is
/// how an overflowing client is unsubscribed: by the terminal, inside its own
/// fan-out loop, where the list is already locked and this client's queue lock
/// is the only other one held. Doing it from the writer thread instead would
/// invert the lock order and deadlock against an attach in flight.
fn onOutput(ctx: *anyopaque, terminal: session.TerminalId, bytes: []const u8) bool {
    const self: *Client = @ptrCast(@alignCast(ctx));
    self.enqueue(.output, terminal, bytes, .drop) catch |err| switch (err) {
        error.ClientBehind => return false,
        else => {},
    };
    return true;
}

fn onExit(ctx: *anyopaque, terminal: session.TerminalId, code: i32) void {
    const self: *Client = @ptrCast(@alignCast(ctx));
    var buf: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"code\":{d}}}", .{code}) catch return;
    self.enqueue(.exited, terminal, body, .drop) catch {};
}

fn detachAll(self: *Client) void {
    for (self.attached.items) |id| {
        if (self.server.terminal(id)) |t| t.unsubscribe(self);
    }
    self.attached.clearRetainingCapacity();
}

fn isAttached(self: *Client, id: session.TerminalId) bool {
    for (self.attached.items) |a| {
        if (a == id) return true;
    }
    return false;
}

fn removeAttached(self: *Client, id: session.TerminalId) void {
    for (self.attached.items, 0..) |a, i| {
        if (a == id) {
            _ = self.attached.swapRemove(i);
            return;
        }
    }
}

/// Push a `sessions_changed` so this client re-issues `list`.
///
/// Called from the server with `clients_mutex` held, so it must not block:
/// `.drop` it is. A client too far behind to take a four-byte notification is
/// already being told to re-attach, and re-attaching re-reads the list anyway.
pub fn notifySessionsChanged(self: *Client) void {
    self.enqueue(.sessions_changed, protocol.control_session, &.{}, .drop) catch {};
}

// -- frame output ----------------------------------------------------------

/// What to do when a frame does not fit in the queue.
const Backpressure = enum {
    /// Wait for room. For this client's own reader thread, which is the only
    /// thread that may block on this client: a reply or a snapshot chunk is
    /// not something we can drop and stay correct.
    wait,
    /// Give up and desync. For terminal reader threads, which must never block
    /// on any one client.
    drop,
};

/// Queue a frame for this client. The client's own thread waits for room;
/// everyone else gets `error.ClientBehind` instead of blocking.
fn send(self: *Client, t: protocol.FrameType, id: session.TerminalId, payload: []const u8) !void {
    return self.enqueue(t, id, payload, .wait);
}

fn enqueue(
    self: *Client,
    frame_type: protocol.FrameType,
    id: session.TerminalId,
    payload: []const u8,
    backpressure: Backpressure,
) !void {
    if (!self.alive.load(.acquire)) return error.ClientGone;
    // A client being sent output is not idle, whichever direction the traffic
    // is going: its queue is in use and freeing it would only mean allocating
    // it again on the next chunk.
    self.touch();

    self.queue_mutex.lock();
    defer self.queue_mutex.unlock();

    var offset: usize = 0;
    while (true) {
        const take = @min(payload.len - offset, protocol.max_payload_len);
        const need = protocol.header_len + take;

        // Once desynced, everything queued behind the error frame is bytes the
        // client will throw away with the terminal it belongs to.
        if (self.desynced) return error.ClientBehind;

        switch (backpressure) {
            .wait => while (self.queue.items.len > 0 and
                self.queue.items.len + need > self.queue_cap)
            {
                self.queue_drained.wait(&self.queue_mutex);
                if (!self.alive.load(.acquire)) return error.ClientGone;
                if (self.desynced) return error.ClientBehind;
                // Only waits while there is something to drain, so a frame
                // larger than the whole queue still goes out on its own.
            },
            .drop => if (self.queue.items.len + need > self.queue_cap) {
                self.desyncLocked(id);
                return error.ClientBehind;
            },
        }

        // Header and payload go in together or not at all: the writer swaps
        // the whole queue out, and half a frame on the wire is unrecoverable.
        self.queue.ensureUnusedCapacity(self.gpa, need) catch {
            // Out of memory partway through a payload. What is queued is a
            // stream with a hole in it, and a client that renders past the
            // hole is wrong rather than merely behind, so treat it the same
            // as an overflow.
            self.desyncLocked(id);
            return error.ClientBehind;
        };
        var header_buf: [protocol.header_len]u8 = undefined;
        const header: protocol.Header = .{
            .type = frame_type,
            .session = id,
            .len = @intCast(take),
        };
        header.encode(&header_buf);
        self.queue.appendSliceAssumeCapacity(&header_buf);
        self.queue.appendSliceAssumeCapacity(payload[offset..][0..take]);

        offset += take;
        // A zero-length payload is one frame, not none.
        if (offset >= payload.len) break;
    }

    self.queue_ready.signal();
}

/// The queue overflowed: tell the client, and drop everything behind it.
///
/// Caller holds `queue_mutex`. The subscription itself is dropped by the
/// terminal, from `onOutput`'s return value.
fn desyncLocked(self: *Client, id: session.TerminalId) void {
    if (self.desynced) return;
    self.desynced = true;

    // What is queued is a prefix of a byte stream the client is about to
    // discard along with its terminal. Dropping it is not a loss, and it is
    // what makes room for the frame that says so.
    self.queue.clearRetainingCapacity();
    // Worth a line in the daemon's log, and worth suppressing in the tests
    // that provoke it on purpose: the build runner surfaces a test step's
    // stderr under a heading that reads like a failure. The tests assert on
    // the frame the client receives, not on this.
    if (!builtin.is_test) {
        log.warn("client fell behind on terminal {d}; forcing a re-attach", .{id});
    }

    var body_buf: [96]u8 = undefined;
    const body = std.fmt.bufPrint(
        &body_buf,
        "{{\"code\":{d},\"message\":\"output queue overflow\"}}",
        .{@intFromEnum(protocol.ErrorCode.desync)},
    ) catch return;

    var header_buf: [protocol.header_len]u8 = undefined;
    const header: protocol.Header = .{
        .type = .err,
        .session = id,
        .len = @intCast(body.len),
    };
    header.encode(&header_buf);
    self.queue.ensureUnusedCapacity(self.gpa, header_buf.len + body.len) catch return;
    self.queue.appendSliceAssumeCapacity(&header_buf);
    self.queue.appendSliceAssumeCapacity(body);
    self.queue_ready.signal();
    // Producers waiting for room are waiting for a stream that no longer
    // exists; the `desynced` check above sends them home.
    self.queue_drained.broadcast();
}

/// Drain the queue to the socket. One thread, so frames leave in the order
/// they were queued no matter which thread queued them.
fn writeLoop(self: *Client) void {
    while (true) {
        {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            while (self.queue.items.len == 0) {
                if (!self.alive.load(.acquire)) return;
                if (self.draining.load(.acquire)) return;
                if (self.park_requested) {
                    self.park_requested = false;
                    // Both buffers belong to this thread at this instant: the
                    // queue is empty and `outgoing` was cleared after the last
                    // write. That is the whole reason parking is asked for
                    // rather than done by the thread that wants it.
                    self.queue.clearAndFree(self.gpa);
                    self.outgoing.clearAndFree(self.gpa);
                }
                self.queue_ready.wait(&self.queue_mutex);
            }
            std.mem.swap(std.ArrayList(u8), &self.queue, &self.outgoing);
            // `queue` is now the buffer the last round wrote from, already
            // cleared, so its capacity is reused rather than reallocated.
            self.queue_drained.broadcast();
        }

        sys.writeAll(self.fd, self.outgoing.items) catch {
            // The far end is gone. Waking the producers matters more than the
            // bytes: they are blocked on room that will never come.
            self.alive.store(false, .release);
            self.wakeQueue();
            return;
        };
        self.outgoing.clearRetainingCapacity();
    }
}

/// A fresh attach starts a fresh stream, so the desync is over.
///
/// Without this a client is told to re-attach once and then never heard from
/// again: `desynced` short-circuits every later enqueue, including the
/// snapshot it just asked for. There is no race with the error frame it is
/// reacting to -- a client cannot answer a frame it has not received, so by
/// the time the `attach` arrives that frame is long written.
fn clearDesync(self: *Client) void {
    self.queue_mutex.lock();
    defer self.queue_mutex.unlock();
    self.desynced = false;
}

// -- buffer parking --------------------------------------------------------
//
// Level 3 of docs/PARKING.md, and the smallest of the three:
//
//   > "when a client attaches, in order to optimize the speed at which a
//   > client could read data from the server, we have a bunch of buffers ...
//   > it adds up. It's kilobytes of buffers. When a client is mostly idle
//   > after a period of time, after the initial synchronization, we park the
//   > buffers, which is basically we free them." -- [MEM t=551]
//
// Kilobytes each, and multiplied by client count at the scale this project
// exists for. A pane that streamed a build log holds the queue capacity that
// took, and a pane that sent one large frame holds a read buffer to match,
// both of them for as long as the window stays open.

/// Free this client's pipeline buffers if it has been quiet long enough.
///
/// Never blocks: the maintenance tick calls this for every client in turn, and
/// one busy connection must not hold up the rest. A client that is mid-frame
/// or mid-write simply keeps its buffers until the next tick.
pub fn parkBuffers(self: *Client, cfg: illogical.park.Config) void {
    const idle = sys.monotonicNs() -| self.last_activity_ns.load(.acquire);
    if (idle < cfg.client_park_after_ns) return;

    // The read buffer, if the reader is not between a header and its dispatch.
    if (self.read_mutex.tryLock()) {
        self.read_payload.clearAndFree(self.gpa);
        self.read_mutex.unlock();
    }

    // The queue is freed by the writer thread instead of here. `outgoing` is
    // inside a `write` for most of its life and only the writer knows when it
    // is not; asking costs one flag and a wake-up.
    self.queue_mutex.lock();
    defer self.queue_mutex.unlock();
    if (self.queue.items.len > 0) return;
    self.park_requested = true;
    self.queue_ready.signal();
}

/// Bytes of capacity this client's pipeline is holding. For tests and for the
/// memory benchmark; not otherwise interesting.
pub fn bufferedCapacity(self: *Client) usize {
    self.queue_mutex.lock();
    const queued = self.queue.capacity + self.outgoing.capacity;
    self.queue_mutex.unlock();

    self.read_mutex.lock();
    defer self.read_mutex.unlock();
    return queued + self.read_payload.capacity;
}

/// Wake both ends of the queue, for a state change they are waiting on.
fn wakeQueue(self: *Client) void {
    self.queue_mutex.lock();
    defer self.queue_mutex.unlock();
    self.queue_ready.signal();
    self.queue_drained.broadcast();
}

fn sendError(
    self: *Client,
    id: session.TerminalId,
    code: protocol.ErrorCode,
    message: []const u8,
) !void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(
        &buf,
        "{{\"code\":{d},\"message\":\"{s}\"}}",
        .{ @intFromEnum(code), message },
    ) catch return;
    try self.send(.err, id, body);
}

// -- tests -----------------------------------------------------------------

/// Encode a snapshot of an 80x24 terminal carrying `lines` of scrollback.
/// Caller owns the bytes.
fn testSnapshot(gpa: Allocator, lines: usize) ![]u8 {
    var tiny: ghostty.TinyIo = .init;
    var vt: ghostty.Terminal = try .init(tiny.io(), gpa, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = null,
    });
    defer vt.deinit(gpa);

    var stream = vt.vtStream();
    defer stream.deinit();

    var line_buf: [64]u8 = undefined;
    for (0..lines) |i| {
        stream.nextSlice(try std.fmt.bufPrint(&line_buf, "line {d}\r\n", .{i}));
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &out);
    try ghostty.snapshot.encode(gpa, &aw.writer, &vt, .{ .continuation = .ground });
    try aw.writer.flush();
    out = aw.toArrayList();
    return out.toOwnedSlice(gpa);
}

/// Scan `bytes` in fixed-size pieces, as the chunker sees them, and return the
/// absolute offset just past READY.
fn scanInPieces(bytes: []const u8, piece: usize) ?usize {
    var scanner: ReadyScanner = .{};
    var offset: usize = 0;
    while (offset < bytes.len) {
        const take = @min(piece, bytes.len - offset);
        if (scanner.scan(bytes[offset..][0..take])) |split| return offset + split;
        offset += take;
    }
    return null;
}

/// Append one record with `tag` and `payload` to `out`, framed the way
/// `record.Writer` frames it. The CRC is not computed: nothing under test
/// validates it, and a wrong one proves the scanner is not reading it.
fn appendRecord(gpa: Allocator, out: *std.ArrayList(u8), tag: u16, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    std.mem.writeInt(u16, header[0..2], tag, .little);
    std.mem.writeInt(u32, header[2..6], @intCast(payload.len), .little);
    std.mem.writeInt(u32, header[6..10], 0xDEADBEEF, .little);
    try out.appendSlice(gpa, &header);
    try out.appendSlice(gpa, payload);
}

test "a READY header inside a payload is skipped by length, not matched" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const ready_tag = @intFromEnum(ghostty.snapshot.record.Tag.ready);
    const page_tag = @intFromEnum(ghostty.snapshot.record.Tag.page);

    // A page payload that contains a well-formed, empty READY header. Page
    // data is mostly zeroes, so this byte sequence is ordinary content, and a
    // scanner that pattern-matched instead of following record lengths would
    // split the stream in the middle of this record.
    var decoy: [40]u8 = @splat(0);
    std.mem.writeInt(u16, decoy[16..18], ready_tag, .little);
    std.mem.writeInt(u32, decoy[18..22], 0, .little);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, ghostty.snapshot.envelope.magic);
    try out.appendSlice(gpa, &.{ 1, 0 });
    try appendRecord(gpa, &out, page_tag, &decoy);
    const real_ready_at = out.items.len + 10;
    try appendRecord(gpa, &out, ready_tag, &.{});
    try appendRecord(gpa, &out, page_tag, &(@as([64]u8, @splat(0))));

    // Every split, because the decoy straddles different boundaries in each.
    for ([_]usize{ 1, 2, 3, 7, 10, 17, 64, 4096 }) |piece| {
        try testing.expectEqual(real_ready_at, scanInPieces(out.items, piece) orelse
            return error.NoReadyMarker);
    }
}

test "a stream with no READY record is reported as such" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const page_tag = @intFromEnum(ghostty.snapshot.record.Tag.page);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, ghostty.snapshot.envelope.magic);
    try out.appendSlice(gpa, &.{ 1, 0 });
    try appendRecord(gpa, &out, page_tag, &(@as([32]u8, @splat(0))));
    try appendRecord(gpa, &out, page_tag, &(@as([8]u8, @splat(0))));

    // This is what makes `attach`'s fallback reachable rather than dead code.
    for ([_]usize{ 1, 7, 4096 }) |piece| {
        try testing.expect(scanInPieces(out.items, piece) == null);
    }
}

test "the READY marker is found at the same offset however the stream is split" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const bytes = try testSnapshot(gpa, 2_000);
    defer gpa.free(bytes);

    const whole = scanInPieces(bytes, bytes.len) orelse return error.NoReadyMarker;
    // History follows READY, so the marker is nowhere near the end. This is
    // the property the whole change exists for.
    try testing.expect(whole < bytes.len);

    // The encoder hands us record-aligned writes; a park file streamed off
    // disk does not. Both have to find the same byte.
    for ([_]usize{ 1, 7, 10, 64, 4096 }) |piece| {
        try testing.expectEqual(whole, scanInPieces(bytes, piece) orelse
            return error.NoReadyMarker);
    }
}

test "the READY prefix decodes into a renderable terminal on its own" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const bytes = try testSnapshot(gpa, 2_000);
    defer gpa.free(bytes);

    const split = scanInPieces(bytes, 4096) orelse return error.NoReadyMarker;

    // Exactly what the client has in hand when `snapshot_ready` arrives.
    var tiny: ghostty.TinyIo = .init;
    var reader: std.Io.Reader = .fixed(bytes[0..split]);
    var decoder: ghostty.snapshot.Decoder = .init(&reader);
    var decoded = try decoder.ready(gpa, tiny.io(), .{
        .max_continuation_bytes = 0,
    });
    defer decoded.deinit(gpa);

    const restored = &(decoded.terminal orelse return error.NoTerminal);
    const text = try restored.plainString(gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "line 1999") != null);
}

test "the chunker frames ready between the right two chunks" {
    const testing = std.testing;
    const gpa = testing.allocator;

    // A real `Client` writing to a real socket, which is all `send` needs:
    // `Server.init` allocates but binds nothing, and no reader thread is
    // started. Reading the other end back gives us the frames in wire order.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &path_buf,
        "/tmp/illogical-chunker-{d}.sock",
        .{std.c.getpid()},
    );
    defer sys.unlinkPath(path.ptr);

    const addr = try sys.unixAddr(path);
    const listener = try sys.unixSocket();
    defer sys.closeFd(listener);
    try sys.bindUnix(listener, &addr);
    try sys.listenFd(listener, 1);
    const reader_fd = try sys.connectUnix(path);
    defer sys.closeFd(reader_fd);
    const writer_fd = try sys.acceptFd(listener);

    const server = try Server.init(gpa, threaded.io(), path, "/tmp/illogical-unused");
    defer server.deinit();
    const client = try Client.create(server, writer_fd);
    defer client.destroy();
    // The writer, but not the reader: nothing is going to send this client a
    // frame, and a reader thread would only have to be woken again to join.
    try client.startWriter();

    // A synthetic stream, not a real snapshot. Nothing drains the far end
    // until this thread finishes writing, so the whole exchange has to fit
    // inside the socket buffer -- a real snapshot is tens of kilobytes and
    // stalls the writer here. The framing is what is under test, and these are
    // the same records.
    const ready_tag = @intFromEnum(ghostty.snapshot.record.Tag.ready);
    const page_tag = @intFromEnum(ghostty.snapshot.record.Tag.page);

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    try stream.appendSlice(gpa, ghostty.snapshot.envelope.magic);
    try stream.appendSlice(gpa, &.{ 1, 0 });
    try appendRecord(gpa, &stream, page_tag, &(@as([200]u8, @splat('a'))));
    const split = stream.items.len + 10;
    try appendRecord(gpa, &stream, ready_tag, &.{});
    try appendRecord(gpa, &stream, page_tag, &(@as([200]u8, @splat('b'))));
    const bytes = stream.items;
    try testing.expect(bytes.len < 1024);

    var chunker = SnapshotChunker.init(client, 7);
    // Ten bytes at a time, the way `record.Writer` emits a header before its
    // payload: that lands READY at the end of a slice rather than inside one,
    // which is the case where an off-by-one would not show up in the offset.
    var offset: usize = 0;
    while (offset < bytes.len) {
        const take = @min(@as(usize, 10), bytes.len - offset);
        try chunker.interface.writeAll(bytes[offset..][0..take]);
        offset += take;
    }
    try chunker.interface.flush();
    try testing.expect(chunker.sent_ready);

    // `flush` only means the frames are queued; the writer thread puts them on
    // the socket. Join it before the half-close below, or the shutdown races
    // the writes it is supposed to follow.
    client.stopWriter();

    // Half-close, so the reader below cannot outlive the frames. Without this
    // a chunker that dropped a byte would leave `readAll` blocked forever on a
    // socket whose write end this same thread still holds open -- the failed
    // assertion would never be reached. Buffered frames survive the FIN, so
    // the success path is unaffected; a starved read now returns zero, which
    // `sys.readAll` reports as an error.
    _ = std.c.shutdown(writer_fd, 1);

    // Read the frames back and reassemble.
    var chunks: std.ArrayList(u8) = .empty;
    defer chunks.deinit(gpa);
    var before_ready: usize = 0;
    var readies: usize = 0;
    var saw_chunk_after_ready = false;

    var header_buf: [protocol.header_len]u8 = undefined;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    while (chunks.items.len < bytes.len or readies == 0) {
        try sys.readAll(reader_fd, &header_buf);
        const header = try protocol.Header.decode(&header_buf);
        try testing.expectEqual(@as(session.TerminalId, 7), header.session);
        try payload.resize(gpa, header.len);
        if (header.len > 0) try sys.readAll(reader_fd, payload.items);

        switch (header.type) {
            .snapshot_chunk => {
                try chunks.appendSlice(gpa, payload.items);
                if (readies == 0) before_ready += payload.items.len else saw_chunk_after_ready = true;
            },
            .snapshot_ready => {
                try testing.expectEqual(@as(u32, 0), header.len);
                readies += 1;
            },
            else => return error.UnexpectedFrame,
        }
    }

    try testing.expectEqual(@as(usize, 1), readies);
    // The marker lands on exactly the byte the client's decoder stops at...
    try testing.expectEqual(split, before_ready);
    // ...history follows it...
    try testing.expect(saw_chunk_after_ready);
    // ...and not one byte was dropped or duplicated by the split.
    try testing.expectEqualSlices(u8, bytes, chunks.items);
}

test "the READY prefix does not grow with scrollback" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const small = try testSnapshot(gpa, 2_000);
    defer gpa.free(small);
    const large = try testSnapshot(gpa, 20_000);
    defer gpa.free(large);

    const small_ready = scanInPieces(small, 4096) orelse return error.NoReadyMarker;
    const large_ready = scanInPieces(large, 4096) orelse return error.NoReadyMarker;

    // Ten times the scrollback, and the whole snapshot grows with it. The
    // prefix the client waits on before it can paint does not: that is the M2
    // gate, and it is the only reason any of this scanning exists.
    try testing.expect(large.len > small.len * 5);

    // An absolute bound, not a ratio: the prefix is the active screen plus
    // whatever of the page it sits in, so it moves by less than one page
    // between two terminals of the same geometry, no matter how much history
    // is behind them. The largest post-READY page record these inputs produce
    // is a little under 8 KiB, so 16 KiB is two pages of slack -- tight enough
    // to catch a partial revert that leaves a page or two ahead of the marker,
    // which is the realistic way this breaks. Observed drift is ~3 KiB.
    const drift = @max(large_ready, small_ready) - @min(large_ready, small_ready);
    try testing.expect(drift < 16 * 1024);
}

// -- flow control ----------------------------------------------------------

/// A connected pair of unix stream sockets, and the paperwork to unlink the
/// path afterwards. `socketpair` would be shorter, but the daemon's socket
/// helpers are what everything else here is built on.
const SocketPair = struct {
    listener: sys.fd_t,
    /// The end a `Client` writes to.
    server_end: sys.fd_t,
    /// The end a test reads frames from.
    client_end: sys.fd_t,
    path_buf: [64]u8 = undefined,
    path_len: usize = 0,

    fn open(tag: []const u8) !SocketPair {
        var self: SocketPair = .{ .listener = -1, .server_end = -1, .client_end = -1 };
        const path = try std.fmt.bufPrintZ(
            &self.path_buf,
            "/tmp/illogical-{s}-{d}.sock",
            .{ tag, std.c.getpid() },
        );
        self.path_len = path.len;
        sys.unlinkPath(path.ptr);

        const addr = try sys.unixAddr(path);
        self.listener = try sys.unixSocket();
        errdefer sys.closeFd(self.listener);
        try sys.bindUnix(self.listener, &addr);
        try sys.listenFd(self.listener, 1);
        self.client_end = try sys.connectUnix(path);
        errdefer sys.closeFd(self.client_end);
        self.server_end = try sys.acceptFd(self.listener);
        return self;
    }

    /// Does not close `server_end`: whichever `Client` was handed it owns it.
    fn close(self: *SocketPair) void {
        sys.closeFd(self.client_end);
        sys.closeFd(self.listener);
        self.path_buf[self.path_len] = 0;
        sys.unlinkPath(@ptrCast(&self.path_buf));
    }
};

/// Read one frame off `fd` into `payload`. Blocks.
fn readFrame(fd: sys.fd_t, gpa: Allocator, payload: *std.ArrayList(u8)) !protocol.Header {
    var header_buf: [protocol.header_len]u8 = undefined;
    try sys.readAll(fd, &header_buf);
    const header = try protocol.Header.decode(&header_buf);
    try payload.resize(gpa, header.len);
    if (header.len > 0) try sys.readAll(fd, payload.items);
    return header;
}

test "fan-out that does not fit is refused, not buffered" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var pair = try SocketPair.open("flow-unit");
    defer pair.close();

    const server = try Server.init(gpa, threaded.io(), "/tmp/illogical-unused.sock", "/tmp/illogical-unused");
    defer server.deinit();
    // Small enough that one ordinary PTY read overflows it.
    server.client_queue_bytes = 256;

    const client = try Client.create(server, pair.server_end);
    defer client.destroy();
    // No writer thread: nothing drains, so the queue is exactly what the
    // producers put there, which is what this test is about.

    // Under the cap, so it is queued whole.
    const small: [100]u8 = @splat('a');
    try client.enqueue(.output, 7, &small, .drop);
    try testing.expectEqual(protocol.header_len + small.len, client.queue.items.len);
    try testing.expect(!client.desynced);

    // Over it. The queue does not grow to fit -- that is the entire point --
    // and what is left is the frame telling the client to start again.
    const rest: [200]u8 = @splat('b');
    try testing.expectError(error.ClientBehind, client.enqueue(.output, 7, &rest, .drop));
    try testing.expect(client.desynced);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    var reader: std.Io.Reader = .fixed(client.queue.items);

    var header_buf: [protocol.header_len]u8 = undefined;
    @memcpy(&header_buf, try reader.take(protocol.header_len));
    const header = try protocol.Header.decode(&header_buf);
    try testing.expectEqual(protocol.FrameType.err, header.type);
    try testing.expectEqual(@as(session.TerminalId, 7), header.session);

    const body = try reader.take(header.len);
    const parsed = try protocol.body.decode(protocol.body.Err, gpa, body);
    defer parsed.deinit();
    try testing.expectEqual(@intFromEnum(protocol.ErrorCode.desync), parsed.value.code);

    // The error frame is the whole queue: everything the client had not read
    // belongs to a terminal it is about to throw away.
    try testing.expectEqual(client.queue.items.len, protocol.header_len + header.len);

    // And once desynced it stays that way, rather than accumulating a second
    // stream behind the first...
    try testing.expectError(error.ClientBehind, client.enqueue(.output, 7, &small, .drop));

    // ...until the client does what it was told and attaches again. Driven
    // through `dispatch` rather than by setting the flag, because the whole
    // point is that this is on the path a real client takes: without it a
    // client is told to re-attach once and then goes permanently quiet, its
    // own snapshot short-circuited by the flag it is trying to clear.
    client.queue.clearRetainingCapacity();
    const attach_body = try protocol.body.encode(gpa, protocol.body.Attach{});
    defer gpa.free(attach_body);
    try client.dispatch(
        .{ .type = .attach, .session = 4242, .len = @intCast(attach_body.len) },
        attach_body,
    );
    try testing.expect(!client.desynced);

    // 4242 is not a terminal, so what came back is `no_such_session` -- but it
    // came back, which is the assertion: the queue is live again.
    try testing.expect(client.queue.items.len > 0);
    try client.enqueue(.output, 7, &small, .drop);
}

// -- session-scoped frames -------------------------------------------------

/// The header of the first frame in `bytes`, and the rest of the buffer.
///
/// The queue rather than the socket: these tests run no writer thread, so what
/// was enqueued is exactly what a client would read, and nothing has to be
/// woken or joined to look at it.
fn firstFrame(bytes: []const u8) !struct { protocol.Header, []const u8 } {
    var header_buf: [protocol.header_len]u8 = undefined;
    if (bytes.len < protocol.header_len) return error.NoFrame;
    @memcpy(&header_buf, bytes[0..protocol.header_len]);
    const header = try protocol.Header.decode(&header_buf);
    return .{ header, bytes[protocol.header_len..][0..header.len] };
}

/// The code carried by the first frame in `bytes`, which must be an `err`.
fn firstErrorCode(gpa: Allocator, bytes: []const u8) !u16 {
    const header, const payload = try firstFrame(bytes);
    if (header.type != .err) return error.NotAnError;
    const parsed = try protocol.body.decode(protocol.body.Err, gpa, payload);
    defer parsed.deinit();
    return parsed.value.code;
}

/// A server with a session in it and nothing else. `sessionByNameLocked` would
/// need a PTY; these tests are about `dispatch` and its error mapping, so the
/// registry entry is put there directly.
fn putTestSession(server: *Server, gpa: Allocator, id: session.Id, name: []const u8) !void {
    server.mutex.lock();
    defer server.mutex.unlock();
    try server.sessions.put(gpa, id, .{ .id = id, .name = try gpa.dupe(u8, name) });
}

test "a rename over the wire renames the session and tells every client" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pair = try SocketPair.open("rename-dispatch");
    defer pair.close();

    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/illogical-rename-d-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const server = try Server.init(gpa, io, "/tmp/illogical-unused.sock", root);
    defer server.deinit();

    const client = try Client.create(server, pair.server_end);
    // Registered, because `notifySessionsChanged` only reaches clients the
    // server knows about -- and that means `Server.deinit` owns it now, so
    // there is no `defer client.destroy()` to go with this.
    server.clients_mutex.lock();
    try server.clients.append(gpa, client);
    server.clients_mutex.unlock();

    try putTestSession(server, gpa, 1, "work");

    const body_bytes = try protocol.body.encode(gpa, protocol.body.RenameSession{
        .session = 1,
        .name = "done",
    });
    defer gpa.free(body_bytes);
    try client.dispatch(.{
        .type = .rename_session,
        .session = protocol.control_session,
        .len = @intCast(body_bytes.len),
    }, body_bytes);

    try testing.expectEqualStrings("done", server.sessions.get(1).?.name);

    // There is no reply frame: `sessions_changed` is the acknowledgement, and
    // the requester gets it along with everybody else, which is what makes
    // "re-list after the broadcast" the client's whole update path.
    const header, const payload = try firstFrame(client.queue.items);
    try testing.expectEqual(protocol.FrameType.sessions_changed, header.type);
    try testing.expectEqual(protocol.control_session, header.session);
    try testing.expectEqual(@as(usize, 0), payload.len);
}

test "a refused rename or delete answers err on the control channel" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pair = try SocketPair.open("rename-refuse-d");
    defer pair.close();

    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/illogical-refuse-d-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const server = try Server.init(gpa, io, "/tmp/illogical-unused.sock", root);
    defer server.deinit();

    const client = try Client.create(server, pair.server_end);
    defer client.destroy();

    try putTestSession(server, gpa, 1, "work");
    try putTestSession(server, gpa, 2, "other");

    // Session 2 gets a terminal with a live child, because `only_if_empty`
    // asks each terminal whether its child has finished rather than counting
    // registry entries -- a phantom id would be skipped and the delete would
    // succeed. No `start`: nothing needs the PTY read, and `finished` stays
    // false while the child is alive, which is the whole condition under test.
    const busy = try Terminal.create(gpa, .{
        .io = io,
        .store = server.store,
        .id = 42,
        .session_id = 2,
        .name = "busy",
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .cols = 80,
        .rows = 24,
    });
    // Hung up before `Server.deinit` destroys it: `destroy` closes the PTY but
    // does not signal, and the child would outlive the suite by half a minute.
    defer busy.hangup();
    server.mutex.lock();
    // Owned by the server from here -- `Server.deinit` destroys everything in
    // this map, so there is no `defer busy.destroy()` to go with it.
    try server.terminals.put(gpa, 42, busy);
    try server.sessions.getPtr(2).?.terminals.append(gpa, 42);
    server.mutex.unlock();

    const Case = struct {
        frame: protocol.FrameType,
        payload: []const u8,
        want: protocol.ErrorCode,
    };
    const cases = [_]Case{
        .{
            .frame = .rename_session,
            .payload = "{\"session\":1,\"name\":\"has space\"}",
            .want = .invalid_name,
        },
        .{
            .frame = .rename_session,
            .payload = "{\"session\":1,\"name\":\"\"}",
            .want = .invalid_name,
        },
        .{
            .frame = .rename_session,
            .payload = "{\"session\":1,\"name\":\"other\"}",
            .want = .name_in_use,
        },
        .{
            .frame = .rename_session,
            .payload = "{\"session\":9999,\"name\":\"anything\"}",
            .want = .no_such_session,
        },
        .{
            .frame = .delete_session,
            .payload = "{\"session\":2,\"only_if_empty\":true}",
            .want = .session_busy,
        },
        .{
            .frame = .delete_session,
            .payload = "{\"session\":9999}",
            .want = .no_such_session,
        },
        // Not a session-scoped frame, but the same rule and the same code:
        // `create` is the other way a name reaches the registry, and it is
        // refused rather than allowed to put wire bytes on disk. The remaining
        // `Create` fields default, so nothing is spawned before the refusal.
        .{
            .frame = .create,
            .payload = "{\"session_name\":\"has space\"}",
            .want = .invalid_name,
        },
        .{
            .frame = .create,
            .payload = "{\"session_name\":\"\"}",
            .want = .invalid_name,
        },
    };

    for (cases) |case| {
        client.queue.clearRetainingCapacity();
        try client.dispatch(.{
            .type = case.frame,
            .session = protocol.control_session,
            .len = @intCast(case.payload.len),
        }, case.payload);
        try testing.expectEqual(
            @intFromEnum(case.want),
            try firstErrorCode(gpa, client.queue.items),
        );
    }

    // Every one of those was a refusal, so nothing moved: the two sessions
    // still have their names and the refused creates added none.
    try testing.expectEqualStrings("work", server.sessions.get(1).?.name);
    try testing.expectEqualStrings("other", server.sessions.get(2).?.name);
    try testing.expectEqual(@as(usize, 2), server.sessions.count());
    try testing.expectEqual(@as(usize, 1), server.terminals.count());
}

test "a delete announces nothing and changes nothing on disk" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pair = try SocketPair.open("delete-quiet");
    defer pair.close();

    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/illogical-delete-q-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const server = try Server.init(gpa, io, "/tmp/illogical-unused.sock", root);
    defer server.deinit();

    const client = try Client.create(server, pair.server_end);
    server.clients_mutex.lock();
    try server.clients.append(gpa, client);
    server.clients_mutex.unlock();

    try putTestSession(server, gpa, 1, "doomed");
    try server.store.writeSessionMeta(io, 1, "doomed");

    const body_bytes = "{\"session\":1}";
    try client.dispatch(.{
        .type = .delete_session,
        .session = protocol.control_session,
        .len = body_bytes.len,
    }, body_bytes);

    // The terminals are on their way out and the registry still lists them, so
    // a `sessions_changed` here would send every client to fetch a list that
    // has not changed. `retireExited` sends it when they have actually gone.
    try testing.expectEqual(@as(usize, 0), client.queue.items.len);

    // And the name is still on disk, because the session still exists. The
    // registry owns `meta.json`'s lifetime, not the request: discarding it
    // here would leave a nameless session listed for as long as a child that
    // ignores SIGHUP took to die, and would delete the name out from under a
    // `create` that landed in that window and reused the session.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const meta = try server.store.sessionMetaPath(&path_buf, 1);
    try std.Io.Dir.cwd().access(io, meta, .{});
    try testing.expect(server.sessions.contains(1));
}

/// A second subscriber that just records what the terminal fanned out.
///
/// Lets a test compare what a client received against what was sent, which is
/// the only part of the path this file is responsible for. Whether the PTY
/// itself delivered every byte the child wrote is a different question, and one
/// a flow-control test should not be asserting.
const Tee = struct {
    mutex: illogical.thread.Mutex = .{},
    bytes: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    fn subscriber(self: *Tee) Terminal.Subscriber {
        return .{ .ctx = self, .writeFn = write, .exitFn = exited };
    }

    fn write(ctx: *anyopaque, _: session.TerminalId, bytes: []const u8) bool {
        const self: *Tee = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.bytes.appendSlice(self.gpa, bytes) catch return false;
        return true;
    }

    fn exited(_: *anyopaque, _: session.TerminalId, _: i32) void {}

    /// A copy of what has been recorded so far. Caller owns it.
    fn snapshot(self: *Tee, gpa: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return gpa.dupe(u8, self.bytes.items);
    }
};

test "an idle client's buffers are freed, and come back on activity" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var pair = try SocketPair.open("park-buffers");
    defer pair.close();

    const server = try Server.init(gpa, threaded.io(), "/tmp/illogical-unused.sock", "/tmp/illogical-unused");
    defer server.deinit();
    // Idle immediately, so the test does not have to wait ten seconds for the
    // behaviour it is checking.
    server.park_config.client_park_after_ns = 0;

    const client = try Client.create(server, pair.server_end);
    defer client.destroy();
    try client.startWriter();

    // Push enough through to grow both the queue and its partner buffer, and
    // drain it so nothing is left pending.
    const chunk: [16 * 1024]u8 = @splat('x');
    for (0..8) |_| try client.enqueue(.output, 1, &chunk, .wait);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    var drained: usize = 0;
    while (drained < 8 * chunk.len) {
        const header = try readFrame(pair.client_end, gpa, &payload);
        drained += header.len;
    }
    try testing.expect(client.bufferedCapacity() >= chunk.len);

    // Also give the read buffer something to hold on to. Driven through
    // `dispatch` because that is the path that grows it in production.
    const big_name: [4096]u8 = @splat('n');
    const body = try protocol.body.encode(gpa, protocol.body.Create{ .name = &big_name });
    defer gpa.free(body);
    client.read_payload.clearRetainingCapacity();
    try client.read_payload.appendSlice(gpa, body);
    try testing.expect(client.read_payload.capacity >= body.len);

    // Park. The queue is freed by the writer thread, so this is a request and
    // the assertion has to wait for it to be honoured.
    client.parkBuffers(server.park_config);
    var waited: usize = 0;
    while (waited < 2000) : (waited += 5) {
        if (client.bufferedCapacity() == 0) break;
        sys.sleepNs(5 * std.time.ns_per_ms);
    } else return error.BuffersNeverParked;

    // Freed, not merely emptied: `clearRetainingCapacity` would leave every
    // byte of that 128 KiB allocated, which is exactly the thing level 3 is
    // about at ten thousand clients.
    try testing.expectEqual(@as(usize, 0), client.bufferedCapacity());

    // And the client still works. Reallocation is the allocator's business,
    // not a state machine we have to get right.
    try client.enqueue(.output, 1, "back to life", .wait);
    const header = try readFrame(pair.client_end, gpa, &payload);
    try testing.expectEqual(protocol.FrameType.output, header.type);
    try testing.expectEqualStrings("back to life", payload.items);
}

test "a busy client keeps its buffers" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var pair = try SocketPair.open("park-busy");
    defer pair.close();

    const server = try Server.init(gpa, threaded.io(), "/tmp/illogical-unused.sock", "/tmp/illogical-unused");
    defer server.deinit();
    server.park_config.client_park_after_ns = 0;

    const client = try Client.create(server, pair.server_end);
    defer client.destroy();
    // No writer thread: whatever is queued stays queued.

    try client.enqueue(.output, 1, "pending", .drop);
    const before = client.bufferedCapacity();
    try testing.expect(before > 0);

    // Idle by the clock, but with bytes the client has not been sent. Freeing
    // here would drop output that nothing is going to send again.
    client.parkBuffers(server.park_config);
    try testing.expectEqual(before, client.bufferedCapacity());
    try testing.expect(!client.park_requested);
}

test "a client that keeps up gets the byte stream whole and in order" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pair = try SocketPair.open("flow-ok");
    defer pair.close();

    const server = try Server.init(gpa, io, "/tmp/illogical-unused.sock", "/tmp/illogical-unused");
    defer server.deinit();

    const client = try Client.create(server, pair.server_end);
    defer client.destroy();
    try client.startWriter();

    const lines = 1000;
    const t = try Terminal.create(gpa, .{
        .io = io,
        .store = .{ .root = "/tmp/illogical-unused" },
        .id = 3,
        .session_id = 1,
        .name = "steady",
        .argv = &.{
            "/bin/sh",                                                       "-c",
            "awk 'BEGIN{for(i=0;i<1000;i++) print \"F2_OK \" i}'; sleep 30",
        },
        .cols = 80,
        .rows = 24,
    });
    defer t.destroy();
    defer t.hangup();

    // Recorded from inside the same fan-out loop, so the comparison below is
    // exactly "what was sent" against "what arrived".
    var tee: Tee = .{ .gpa = gpa };
    defer tee.bytes.deinit(gpa);
    try t.subscribe(tee.subscriber());
    try t.subscribe(.{ .ctx = client, .writeFn = onOutput, .exitFn = onExit });
    try t.start();

    // Drain as fast as the terminal produces, which is what a real client
    // does. Nothing here should overflow, so nothing should desync.
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(gpa);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    var frames: usize = 0;
    while (frames < 100_000) : (frames += 1) {
        const header = try readFrame(pair.client_end, gpa, &payload);
        // An `err` here would mean the queue overflowed on a client that was
        // never behind, which is the regression this test exists to catch.
        try testing.expectEqual(protocol.FrameType.output, header.type);
        try testing.expectEqual(@as(session.TerminalId, 3), header.session);
        try received.appendSlice(gpa, payload.items);
        if (std.mem.indexOf(u8, received.items, "F2_OK 999") != null) break;
    } else return error.OutputNeverArrived;

    try testing.expect(!client.desynced);
    try testing.expectEqual(@as(u32, 2), t.attachedCount());
    // Enough traffic to have crossed many frames and several queue swaps.
    try testing.expect(received.items.len > lines * 8);

    // What the client got is an exact prefix of what the terminal sent:
    // nothing dropped, nothing duplicated, nothing reordered, no torn frame.
    // A prefix rather than the whole recording because the loop above stops at
    // the last line while the child is still running.
    //
    // Against the fan-out, not against the child's output, and that is not
    // laziness. An earlier version of this test looked for `F2_OK <i>\r\n` a
    // thousand times and failed about one run in five, because a macOS pty
    // whose output queue fills mid-write restarts its `\n` -> `\r\n`
    // expansion and emits `\r\r\n`. Nothing is lost -- the byte counts come
    // out *above* what the child wrote, not below -- and forwarding it
    // verbatim is exactly right for a server that never re-encodes what the
    // program wrote (docs/PROTOCOL.md, rule 1). The property this file owns is
    // that the queue does not change the stream, so that is what it asserts.
    const sent = try tee.snapshot(gpa);
    defer gpa.free(sent);
    try testing.expect(sent.len >= received.items.len);
    try testing.expectEqualSlices(u8, sent[0..received.items.len], received.items);
}

test "a client that stops reading is unsubscribed, not allowed to stall the terminal" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pair = try SocketPair.open("flow-stall");
    defer pair.close();

    const server = try Server.init(gpa, io, "/tmp/illogical-unused.sock", "/tmp/illogical-unused");
    defer server.deinit();
    server.client_queue_bytes = 16 * 1024;

    const client = try Client.create(server, pair.server_end);
    defer client.destroy();
    try client.startWriter();

    // A child that writes far more than the socket buffer and the queue put
    // together, so the writer thread ends up blocked in `write` with the queue
    // filling behind it -- which is the case this whole change is about.
    const t = try Terminal.create(gpa, .{
        .io = io,
        .store = .{ .root = "/tmp/illogical-unused" },
        .id = 7,
        .session_id = 1,
        .name = "spew",
        .argv = &.{
            "/bin/sh",                                                                                                                "-c",
            "awk 'BEGIN{for(i=0;i<200000;i++) print \"line \" i \" ---- filler to make this a realistic terminal line\"}'; sleep 30",
        },
        .cols = 80,
        .rows = 24,
    });
    defer t.destroy();
    defer t.hangup();

    try t.subscribe(.{ .ctx = client, .writeFn = onOutput, .exitFn = onExit });
    try testing.expectEqual(@as(u32, 1), t.attachedCount());
    try t.start();

    // The terminal drops the subscriber itself, from inside its fan-out loop.
    // Nothing here reads the socket, so this only happens if the fan-out
    // refused to wait on it.
    var waited: usize = 0;
    while (waited < 10_000) : (waited += 10) {
        if (t.attachedCount() == 0) break;
        sys.sleepNs(10 * std.time.ns_per_ms);
    } else return error.SubscriberNeverDropped;

    // And the terminal is unharmed: still live, still reading, still holding
    // the screen the child has been writing to all along.
    const before = t.summary().pty_read_idle_ns;
    _ = before;
    try testing.expectEqual(session.Residency.live, t.summary().residency);
    const text = try t.plainText(gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "line ") != null);

    // Drain the socket until the desync frame turns up. Everything ahead of it
    // is output the client was sent before it fell behind.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    var frames: usize = 0;
    const desync = while (frames < 100_000) : (frames += 1) {
        const header = try readFrame(pair.client_end, gpa, &payload);
        if (header.type == .err) break header;
        try testing.expectEqual(protocol.FrameType.output, header.type);
    } else return error.NoDesyncFrame;

    const parsed = try protocol.body.decode(protocol.body.Err, gpa, payload.items);
    defer parsed.deinit();
    try testing.expectEqual(@intFromEnum(protocol.ErrorCode.desync), parsed.value.code);
    try testing.expectEqual(@as(session.TerminalId, 7), desync.session);
}
