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
store: illogical.park.Store,
park_config: illogical.park.Config = .{},
listener: sys.fd_t = -1,

/// Guards the session/terminal tables and the id counters.
mutex: illogical.thread.Mutex = .{},
sessions: std.AutoArrayHashMapUnmanaged(session.Id, Session) = .empty,
terminals: std.AutoArrayHashMapUnmanaged(session.TerminalId, *Terminal) = .empty,
next_session_id: session.Id = 1,
next_terminal_id: session.TerminalId = 1,

clients_mutex: illogical.thread.Mutex = .{},
clients: std.ArrayList(*Client) = .empty,
/// Bound on one client's queued, not-yet-written output. A field rather than a
/// constant so tests can make overflow reachable without shipping a megabyte
/// at it.
client_queue_bytes: usize = Client.default_queue_bytes,

running: std.atomic.Value(bool) = .init(false),
maintenance: ?std.Thread = null,

pub fn init(gpa: Allocator, io: std.Io, socket_path: []const u8, state_root: []const u8) !*Server {
    const self = try gpa.create(Server);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .socket_path = try gpa.dupe(u8, socket_path),
        .store = .{ .root = try gpa.dupe(u8, state_root) },
    };
    return self;
}

pub fn deinit(self: *Server) void {
    self.stop();
    if (self.maintenance) |t| {
        t.join();
        self.maintenance = null;
    }

    // Take the list out from under the lock before destroying anything.
    // `Client.destroy` joins the client's reader thread, and that thread
    // reaches back into the server as it unwinds -- holding `clients_mutex`
    // across the join would have the two wait on each other.
    self.clients_mutex.lock();
    var clients = self.clients;
    self.clients = .empty;
    self.clients_mutex.unlock();
    for (clients.items) |c| c.destroy();
    clients.deinit(self.gpa);

    self.mutex.lock();
    for (self.terminals.values()) |t| t.destroy();
    self.terminals.deinit(self.gpa);
    for (self.sessions.values()) |*s| s.deinit(self.gpa);
    self.sessions.deinit(self.gpa);
    self.mutex.unlock();

    self.gpa.free(self.socket_path);
    self.gpa.free(self.store.root);
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
    self.maintenance = try std.Thread.spawn(.{}, maintenanceLoop, .{self});
    log.info("listening on {s}", .{self.socket_path});
}

/// Periodic housekeeping: park idle terminals, and give live ones a bounded
/// slice of scrollback compression. See docs/PARKING.md.
pub fn maintenanceTick(self: *Server) void {
    self.retireExited();
    self.retireClients();

    // Copy the terminal list so the registry lock is not held across the work.
    var ids: std.ArrayList(session.TerminalId) = .empty;
    defer ids.deinit(self.gpa);
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        ids.appendSlice(self.gpa, self.terminals.keys()) catch return;
    }

    for (ids.items) |id| {
        const t = self.terminal(id) orelse continue;
        const summary = t.summary();
        if (illogical.park.shouldPark(
            self.park_config,
            summary.residency,
            summary.pty_read_idle_ns,
            summary.attached,
        )) {
            t.park() catch |err| log.warn("terminal {d} failed to park: {t}", .{ id, err });
        } else if (summary.residency == .live) {
            t.compressStep();
        }
    }
}

fn maintenanceLoop(self: *Server) void {
    while (self.running.load(.acquire)) {
        sys.sleepNs(250 * std.time.ns_per_ms);
        self.maintenanceTick();
    }
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

/// Accept connections until stopped. Each client gets a reader and a writer
/// thread of its own; see `Client`.
pub fn run(self: *Server) !void {
    while (self.running.load(.acquire)) {
        const fd = sys.acceptFd(self.listener) catch break;
        const client = Client.create(self, fd) catch |err| {
            log.err("failed to create client: {t}", .{err});
            sys.closeFd(fd);
            continue;
        };

        self.clients_mutex.lock();
        const tracked = if (self.clients.append(self.gpa, client)) true else |_| false;
        self.clients_mutex.unlock();
        if (!tracked) {
            // Untracked means nothing would ever retire it. Better to refuse
            // the connection than to leak the socket and the client with it.
            log.err("out of memory registering a client; dropping the connection", .{});
            client.destroy();
            continue;
        }

        client.start() catch |err| {
            log.err("failed to start client: {t}", .{err});
            // Nothing will set this from the inside: the reader thread that
            // normally does is the one that failed to start. Without it the
            // client sits in the list until the daemon exits.
            client.finished.store(true, .release);
        };
    }
}

/// Tell every client the session/terminal list changed, so they refresh.
///
/// Without this a client only learns about new or gone terminals when it
/// happens to ask, which is why an exited terminal's tab used to linger.
pub fn notifySessionsChanged(self: *Server) void {
    self.clients_mutex.lock();
    defer self.clients_mutex.unlock();
    for (self.clients.items) |c| c.notifySessionsChanged();
}

/// Retire terminals whose child has exited: unregister, then destroy.
///
/// This runs on the maintenance tick rather than in the reader thread, because
/// destroying a terminal joins that very thread.
fn retireExited(self: *Server) void {
    var retired: std.ArrayList(*Terminal) = .empty;
    defer retired.deinit(self.gpa);

    {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.terminals.count()) {
            const t = self.terminals.values()[i];
            if (!t.finished.load(.acquire)) {
                i += 1;
                continue;
            }
            const id = self.terminals.keys()[i];
            _ = self.terminals.orderedRemove(id);
            if (self.sessions.getPtr(t.session_id)) |s| {
                for (s.terminals.items, 0..) |tid, j| {
                    if (tid == id) {
                        _ = s.terminals.orderedRemove(j);
                        break;
                    }
                }
            }
            retired.append(self.gpa, t) catch {};
            // Not incrementing: removal shifted the next entry into this slot.
        }

        // Drop sessions that have no terminals left.
        var si: usize = 0;
        while (si < self.sessions.count()) {
            const s = self.sessions.values()[si];
            if (s.terminals.items.len > 0) {
                si += 1;
                continue;
            }
            const sid = self.sessions.keys()[si];
            var removed = self.sessions.fetchOrderedRemove(sid).?;
            removed.value.deinit(self.gpa);
        }
    }

    if (retired.items.len == 0) return;
    for (retired.items) |t| {
        log.info("terminal {d} exited, retiring", .{t.id});
        t.store.discard(self.io, t.id);
        t.destroy();
    }
    self.notifySessionsChanged();
}

/// Retire clients whose reader thread has finished: unregister, then destroy.
///
/// Like `retireExited`, this runs on the maintenance tick rather than on the
/// thread that noticed, because destroying a client joins that very thread.
/// Before this existed nothing freed a disconnected client at all: it removed
/// itself from the list and left the object, its buffers and its detached
/// thread behind -- a leak per connection, and a thread still using memory
/// `Server.deinit` would later free.
fn retireClients(self: *Server) void {
    var retired: std.ArrayList(*Client) = .empty;
    defer retired.deinit(self.gpa);

    {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const c = self.clients.items[i];
            if (!c.finished.load(.acquire)) {
                i += 1;
                continue;
            }
            _ = self.clients.swapRemove(i);
            retired.append(self.gpa, c) catch {};
        }
    }

    // Outside the lock: destroying joins threads that take it.
    for (retired.items) |c| c.destroy();
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
        .io = self.io,
        .store = self.store,
        .park_config = self.park_config,
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

/// Close a terminal. `signal` of zero means "hang up", which is what a client
/// closing a tab wants; anything else is sent to the process group verbatim.
pub fn killTerminal(self: *Server, id: session.TerminalId, signal: i32) !void {
    const t = self.terminal(id) orelse return error.NoSuchTerminal;
    if (signal == 0) return t.hangup();
    sys.signalGroup(t.child, @intCast(signal));
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
