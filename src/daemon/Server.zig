//! The illogical session server.
//!
//! Owns every session, every terminal, and every client connection. Sessions
//! and terminals outlive clients: closing the last client detaches, it never
//! kills.

const Server = @This();

const std = @import("std");
const sys = illogical.sys;
const Allocator = std.mem.Allocator;
const illogical = @import("illogical");
const protocol = illogical.protocol;
const session = illogical.session;
const Terminal = @import("Terminal.zig");
const Client = @import("Client.zig");

const log = std.log.scoped(.server);

pub const Session = struct {
    id: session.Id,
    name: []u8,
    terminals: std.ArrayList(session.TerminalId) = .empty,

    fn deinit(self: *Session, gpa: Allocator) void {
        self.terminals.deinit(gpa);
        gpa.free(self.name);
    }
};

gpa: Allocator,
io: std.Io,
socket_path: []const u8,
listener: sys.fd_t = -1,

/// Guards the session/terminal tables and the id counters.
mutex: illogical.thread.Mutex = .{},
sessions: std.AutoArrayHashMapUnmanaged(session.Id, Session) = .empty,
terminals: std.AutoArrayHashMapUnmanaged(session.TerminalId, *Terminal) = .empty,
next_session_id: session.Id = 1,
next_terminal_id: session.TerminalId = 1,

clients_mutex: illogical.thread.Mutex = .{},
clients: std.ArrayList(*Client) = .empty,

running: std.atomic.Value(bool) = .init(false),

pub fn init(gpa: Allocator, io: std.Io, socket_path: []const u8) !*Server {
    const self = try gpa.create(Server);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .socket_path = try gpa.dupe(u8, socket_path),
    };
    return self;
}

pub fn deinit(self: *Server) void {
    self.stop();

    self.clients_mutex.lock();
    for (self.clients.items) |c| c.destroy();
    self.clients.deinit(self.gpa);
    self.clients_mutex.unlock();

    self.mutex.lock();
    for (self.terminals.values()) |t| t.destroy();
    self.terminals.deinit(self.gpa);
    for (self.sessions.values()) |*s| s.deinit(self.gpa);
    self.sessions.deinit(self.gpa);
    self.mutex.unlock();

    self.gpa.free(self.socket_path);
    self.gpa.destroy(self);
}

pub fn listen(self: *Server) !void {
    const cwd: std.Io.Dir = .cwd();
    if (std.fs.path.dirname(self.socket_path)) |dir| {
        // Best effort: the directory usually exists, and on macOS a path
        // through a symlink like /tmp reports NotDir rather than succeeding.
        // If it genuinely is missing, bind reports it clearly enough.
        cwd.createDirPath(self.io, dir) catch {};
    }
    // A stale socket from a crashed daemon would make bind fail.
    cwd.deleteFile(self.io, self.socket_path) catch {};

    const addr = try sys.unixAddr(self.socket_path);
    const fd = try sys.unixSocket();
    errdefer sys.closeFd(fd);
    try sys.bindUnix(fd, &addr);
    try sys.listenFd(fd, 64);
    self.listener = fd;
    self.running.store(true, .release);
    log.info("listening on {s}", .{self.socket_path});
}

pub fn stop(self: *Server) void {
    if (!self.running.swap(false, .acq_rel)) return;
    if (self.listener >= 0) {
        sys.closeFd(self.listener);
        self.listener = -1;
    }
    const cwd: std.Io.Dir = .cwd();
    cwd.deleteFile(self.io, self.socket_path) catch {};
}

/// Accept connections until stopped. Each client gets its own thread.
pub fn run(self: *Server) !void {
    while (self.running.load(.acquire)) {
        const fd = sys.acceptFd(self.listener) catch break;
        const client = Client.create(self, fd) catch |err| {
            log.err("failed to create client: {t}", .{err});
            sys.closeFd(fd);
            continue;
        };
        self.clients_mutex.lock();
        self.clients.append(self.gpa, client) catch {};
        self.clients_mutex.unlock();
        client.start() catch |err| log.err("failed to start client: {t}", .{err});
    }
}

pub fn removeClient(self: *Server, client: *Client) void {
    self.clients_mutex.lock();
    defer self.clients_mutex.unlock();
    for (self.clients.items, 0..) |c, i| {
        if (c == client) {
            _ = self.clients.swapRemove(i);
            return;
        }
    }
}

// -- registry --------------------------------------------------------------

/// Find a session by name, or create one.
fn sessionByNameLocked(self: *Server, name: []const u8) !session.Id {
    for (self.sessions.values()) |s| {
        if (std.mem.eql(u8, s.name, name)) return s.id;
    }
    const id = self.next_session_id;
    self.next_session_id += 1;
    try self.sessions.put(self.gpa, id, .{
        .id = id,
        .name = try self.gpa.dupe(u8, name),
    });
    return id;
}

pub const CreateResult = struct {
    terminal: session.TerminalId,
    session: session.Id,
};

pub fn createTerminal(self: *Server, req: protocol.body.Create) !CreateResult {
    self.mutex.lock();
    defer self.mutex.unlock();

    const sid = try self.sessionByNameLocked(req.session_name);
    const tid = self.next_terminal_id;
    self.next_terminal_id += 1;

    var name_buf: [32]u8 = undefined;
    const name = if (req.name.len > 0)
        req.name
    else
        try std.fmt.bufPrint(&name_buf, "{d}", .{tid});

    const default_argv = [_][]const u8{defaultShell()};
    const argv: []const []const u8 = if (req.argv.len > 0) req.argv else &default_argv;

    // A terminal always has a working directory, because clients label tabs
    // with it. Fall back to the user's home rather than reporting nothing.
    const cwd = req.cwd orelse sys.getenv("HOME") orelse "/";

    const t = try Terminal.create(self.gpa, .{
        .id = tid,
        .session_id = sid,
        .name = name,
        .argv = argv,
        .cwd = cwd,
        .cols = req.cols,
        .rows = req.rows,
    });
    errdefer t.destroy();

    try self.terminals.put(self.gpa, tid, t);
    try self.sessions.getPtr(sid).?.terminals.append(self.gpa, tid);
    try t.start();

    log.info("created terminal {d} in session {d} ({s})", .{ tid, sid, name });
    return .{ .terminal = tid, .session = sid };
}

pub fn terminal(self: *Server, id: session.TerminalId) ?*Terminal {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.terminals.get(id);
}

pub fn killTerminal(self: *Server, id: session.TerminalId, signal: i32) !void {
    const t = self.terminal(id) orelse return error.NoSuchTerminal;
    sys.signal(t.child, @intCast(signal));
}

/// Snapshot of the registry for a `list` reply. Caller owns the arena.
pub fn listInto(self: *Server, arena: Allocator) !protocol.body.SessionList {
    self.mutex.lock();
    defer self.mutex.unlock();

    var sessions: std.ArrayList(protocol.body.SessionInfo) = .empty;
    for (self.sessions.values()) |s| {
        try sessions.append(arena, .{
            .id = s.id,
            .name = try arena.dupe(u8, s.name),
            .terminals = try arena.dupe(session.TerminalId, s.terminals.items),
        });
    }

    var terms: std.ArrayList(protocol.body.TerminalInfo) = .empty;
    for (self.terminals.values()) |t| {
        const sum = t.summary();
        try terms.append(arena, .{
            .id = sum.id,
            .session = sum.session,
            .name = try arena.dupe(u8, sum.name),
            .command = try arena.dupe(u8, sum.command),
            .cwd = try arena.dupe(u8, sum.cwd),
            .cols = sum.cols,
            .rows = sum.rows,
            .residency = @tagName(sum.residency),
            .attached = sum.attached,
            .pty_read_idle_ns = sum.pty_read_idle_ns,
            .exit_code = sum.exit_code,
        });
    }

    return .{ .sessions = sessions.items, .terminals = terms.items };
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    return sys.getenv(name);
}

fn defaultShell() []const u8 {
    return getenv("SHELL") orelse "/bin/sh";
}

/// Default control socket path.
pub fn defaultSocketPath(alloc: Allocator) ![]u8 {
    if (getenv("ILLOGICAL_SOCK")) |p| return alloc.dupe(u8, p);
    if (getenv("XDG_STATE_HOME")) |state| {
        return std.fmt.allocPrint(alloc, "{s}/illogical/server.sock", .{state});
    }
    const home = getenv("HOME") orelse "/tmp";
    return std.fmt.allocPrint(alloc, "{s}/.local/state/illogical/server.sock", .{home});
}
