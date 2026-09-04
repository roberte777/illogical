//! One client connection.
//!
//! Reads frames on a dedicated thread and dispatches them. Output flows the
//! other way, pushed by whichever terminal reader thread produced it, so the
//! socket write path is guarded by its own lock.

const Client = @This();

const std = @import("std");
const sys = illogical.sys;
const Allocator = std.mem.Allocator;
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
            const req = protocol.body.decode(protocol.body.Kill, arena, payload) catch null;
            defer if (req) |r| r.deinit();
            const signal = if (req) |r| r.value.signal else 15;
            try self.server.killTerminal(header.session, signal);
        },

        .peek => {
            const t = self.server.terminal(header.session) orelse
                return self.sendError(header.session, .no_such_session, "no such terminal");
            const text = try t.plainText(arena);
            try self.send(.screen, header.session, text);
        },

        .ping => try self.send(.pong, header.session, payload),

        else => return error.UnexpectedFrame,
    }
}

// -- attach ----------------------------------------------------------------

/// Frames snapshot bytes as they are produced, so the client can start
/// decoding before the encode finishes. See docs/PROTOCOL.md.
const SnapshotChunker = struct {
    client: *Client,
    terminal_id: session.TerminalId,
    interface: std.Io.Writer,
    buf: [32 * 1024]u8 = undefined,

    fn init(client: *Client, terminal_id: session.TerminalId) SnapshotChunker {
        return .{
            .client = client,
            .terminal_id = terminal_id,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SnapshotChunker = @fieldParentPtr("interface", w);
        var written: usize = 0;
        for (data, 0..) |slice, i| {
            const times = if (i == data.len - 1) splat else 1;
            for (0..times) |_| {
                if (slice.len == 0) continue;
                self.client.send(.snapshot_chunk, self.terminal_id, slice) catch
                    return error.WriteFailed;
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
    try chunker.interface.flush();

    try self.send(.snapshot_ready, id, &.{});
    try self.send(.snapshot_end, id, &.{});
    try self.attached.append(self.gpa, id);
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
