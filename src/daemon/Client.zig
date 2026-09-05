//! One client connection.
//!
//! Reads frames on a dedicated thread and dispatches them. Output flows the
//! other way, pushed by whichever terminal reader thread produced it, so the
//! socket write path is guarded by its own lock.

const Client = @This();

const std = @import("std");
const sys = illogical.sys;
const Allocator = std.mem.Allocator;
const ghostty = @import("ghostty-vt");
const illogical = @import("illogical");
const protocol = illogical.protocol;
const session = illogical.session;
const Server = @import("Server.zig");
const Terminal = @import("Terminal.zig");

const log = std.log.scoped(.client);

server: *Server,
fd: sys.fd_t,
gpa: Allocator,

/// Serializes socket writes: terminal reader threads push output through here.
write_mutex: illogical.thread.Mutex = .{},
attached: std.ArrayList(session.TerminalId) = .empty,
thread: ?std.Thread = null,
alive: std.atomic.Value(bool) = .init(true),

pub fn create(server: *Server, fd: sys.fd_t) !*Client {
    const self = try server.gpa.create(Client);
    self.* = .{ .server = server, .fd = fd, .gpa = server.gpa };
    return self;
}

pub fn destroy(self: *Client) void {
    self.detachAll();
    if (self.alive.swap(false, .acq_rel)) sys.closeFd(self.fd);
    if (self.thread) |t| {
        t.detach();
        self.thread = null;
    }
    self.attached.deinit(self.gpa);
    self.gpa.destroy(self);
}

pub fn start(self: *Client) !void {
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

fn run(self: *Client) void {
    defer {
        self.detachAll();
        self.server.removeClient(self);
        if (self.alive.swap(false, .acq_rel)) sys.closeFd(self.fd);
    }

    var header_buf: [protocol.header_len]u8 = undefined;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.gpa);

    while (self.alive.load(.acquire)) {
        self.readExact(&header_buf) catch break;
        const header = protocol.Header.decode(&header_buf) catch |err| {
            log.warn("bad frame header: {t}", .{err});
            break;
        };

        payload.clearRetainingCapacity();
        payload.resize(self.gpa, header.len) catch break;
        if (header.len > 0) self.readExact(payload.items) catch break;

        self.dispatch(header, payload.items) catch |err| {
            log.warn("frame {t} failed: {t}", .{ header.type, err });
            self.sendError(header.session, .unknown, @errorName(err)) catch break;
        };
    }
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
                return self.sendError(
                    protocol.control_session,
                    .version_mismatch,
                    "unsupported protocol version",
                );
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
            const result = try self.server.createTerminal(req.value);
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
            try t.resize(req.value.cols, req.value.rows);
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

    if (req.cols > 0 and req.rows > 0) try t.resize(req.cols, req.rows);

    const begin = try protocol.body.encode(self.gpa, protocol.body.SnapshotBegin{});
    defer self.gpa.free(begin);
    try self.send(.snapshot_begin, id, begin);

    var chunker = SnapshotChunker.init(self, id);
    // Subscribe and snapshot under the terminal's lock, so the client gets
    // every byte after the snapshot and none from before it.
    try t.attach(.{
        .ctx = self,
        .writeFn = onOutput,
        .exitFn = onExit,
    }, &chunker.interface);
    // We are a subscriber from here, and `detachAll` only knows about ids in
    // `attached`. Record it before anything that can fail: a client that closes
    // its socket during the two frames below makes those `send`s return EPIPE,
    // and without this the subscriber outlives the connection -- fanned out to
    // on every PTY read for the life of the daemon, and counted forever by
    // `illogical list`. It also means `currentTerminal` is right for output the
    // reader thread produces the moment `attach` releases the terminal lock.
    errdefer {
        t.unsubscribe(self);
        self.removeAttached(id);
    }
    // Not `append` alone: a second `attach` for the same terminal on one
    // connection is desync recovery, and it must replace this client's
    // registration rather than add a second one.
    self.removeAttached(id);
    try self.attached.append(self.gpa, id);

    // The chunker sends `snapshot_ready` the moment the encoder passes READY.
    // If the scan never found it — a snapshot format change, a truncated park
    // file — send it here, so the client paints a blank screen and takes live
    // output rather than waiting forever.
    if (!chunker.sent_ready) try self.send(.snapshot_ready, id, &.{});
    try self.send(.snapshot_end, id, &.{});
}

fn onOutput(ctx: *anyopaque, bytes: []const u8) void {
    const self: *Client = @ptrCast(@alignCast(ctx));
    // TODO(M4): bounded queue + drop-to-reattach instead of a blocking write.
    self.sendRaw(.output, self.currentTerminal(), bytes) catch {};
}

fn onExit(ctx: *anyopaque, code: i32) void {
    const self: *Client = @ptrCast(@alignCast(ctx));
    var buf: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"code\":{d}}}", .{code}) catch return;
    self.sendRaw(.exited, self.currentTerminal(), body) catch {};
}

/// A client attached to exactly one terminal per connection (one connection per
/// terminal, per docs/PROTOCOL.md). This returns that terminal.
fn currentTerminal(self: *Client) session.TerminalId {
    return if (self.attached.items.len > 0)
        self.attached.items[self.attached.items.len - 1]
    else
        protocol.control_session;
}

fn detachAll(self: *Client) void {
    for (self.attached.items) |id| {
        if (self.server.terminal(id)) |t| t.unsubscribe(self);
    }
    self.attached.clearRetainingCapacity();
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
pub fn notifySessionsChanged(self: *Client) void {
    self.sendRaw(.sessions_changed, protocol.control_session, &.{}) catch {};
}

// -- frame output ----------------------------------------------------------

fn send(self: *Client, t: protocol.FrameType, id: session.TerminalId, payload: []const u8) !void {
    return self.sendRaw(t, id, payload);
}

fn sendRaw(
    self: *Client,
    frame_type: protocol.FrameType,
    id: session.TerminalId,
    payload: []const u8,
) !void {
    if (!self.alive.load(.acquire)) return error.ClientGone;

    self.write_mutex.lock();
    defer self.write_mutex.unlock();

    var offset: usize = 0;
    while (offset < payload.len or offset == 0) {
        const take = @min(payload.len - offset, protocol.max_payload_len);
        var header_buf: [protocol.header_len]u8 = undefined;
        const header: protocol.Header = .{
            .type = frame_type,
            .session = id,
            .len = @intCast(take),
        };
        header.encode(&header_buf);
        try sys.writeAll(self.fd, &header_buf);
        if (take > 0) try sys.writeAll(self.fd, payload[offset..][0..take]);
        offset += take;
        if (offset >= payload.len) break;
    }
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
    try self.sendRaw(.err, id, body);
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

    // A synthetic stream, not a real snapshot. `send` writes to the socket
    // synchronously and nothing is draining the far end until this thread
    // finishes writing, so the whole exchange has to fit inside the socket
    // buffer -- a real snapshot is tens of kilobytes and deadlocks here. The
    // framing is what is under test, and these are the same records.
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

    // An absolute bound, not a ratio. The prefix is the active screen plus
    // whatever of the page it sits in, so it moves by less than one page
    // between any two terminals of the same geometry. A ratio would pass a
    // regression that put two or three history pages ahead of READY, which is
    // the realistic way this breaks -- and it is what a partial revert of the
    // scanner would look like.
    const drift = @max(large_ready, small_ready) - @min(large_ready, small_ready);
    try testing.expect(drift < 64 * 1024);
}
