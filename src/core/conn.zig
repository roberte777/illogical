//! A protocol connection.
//!
//! Shared by the CLI and by anything else that speaks to illogicald. Frames are
//! read and written synchronously; callers that want concurrency give the read
//! and write halves to different threads and serialize writes themselves.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const sys = @import("sys.zig");
const thread = @import("thread.zig");

pub const Frame = struct {
    header: protocol.Header,
    /// Borrowed from the connection's read buffer; valid until the next read.
    payload: []const u8,
};

pub const Conn = struct {
    fd: sys.fd_t,
    gpa: Allocator,
    read_buf: std.ArrayList(u8) = .empty,
    write_mutex: thread.Mutex = .{},

    pub fn connect(gpa: Allocator, path: []const u8) !Conn {
        return .{ .fd = try sys.connectUnix(path), .gpa = gpa };
    }

    pub fn deinit(self: *Conn) void {
        sys.closeFd(self.fd);
        self.read_buf.deinit(self.gpa);
    }

    pub fn send(
        self: *Conn,
        frame_type: protocol.FrameType,
        id: u64,
        payload: []const u8,
    ) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        var header_buf: [protocol.header_len]u8 = undefined;
        const header: protocol.Header = .{
            .type = frame_type,
            .session = id,
            .len = @intCast(payload.len),
        };
        header.encode(&header_buf);
        try sys.writeAll(self.fd, &header_buf);
        if (payload.len > 0) try sys.writeAll(self.fd, payload);
    }

    pub fn sendJson(
        self: *Conn,
        frame_type: protocol.FrameType,
        id: u64,
        value: anytype,
    ) !void {
        const bytes = try protocol.body.encode(self.gpa, value);
        defer self.gpa.free(bytes);
        try self.send(frame_type, id, bytes);
    }

    /// Read one frame. The payload is only valid until the next call.
    pub fn recv(self: *Conn) !Frame {
        var header_buf: [protocol.header_len]u8 = undefined;
        try sys.readAll(self.fd, &header_buf);
        const header = try protocol.Header.decode(&header_buf);

        self.read_buf.clearRetainingCapacity();
        try self.read_buf.resize(self.gpa, header.len);
        if (header.len > 0) try sys.readAll(self.fd, self.read_buf.items);
        return .{ .header = header, .payload = self.read_buf.items };
    }

    /// Handshake. Returns the server version, allocated by the caller's arena.
    pub fn hello(self: *Conn, arena: Allocator, client_name: []const u8) ![]const u8 {
        try self.sendJson(.hello, protocol.control_session, protocol.body.Hello{
            .client = client_name,
        });
        const frame = try self.recv();
        if (frame.header.type == .err) return error.HandshakeRejected;
        if (frame.header.type != .welcome) return error.UnexpectedFrame;
        const parsed = try protocol.body.decode(protocol.body.Welcome, arena, frame.payload);
        return parsed.value.server;
    }
};
