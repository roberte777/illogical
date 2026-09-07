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
/// The park key, owned here so `store.key` can point at one copy instead of
/// every terminal carrying thirty-two bytes of its own. Must not move: the
/// store and every terminal's copy of it hold this address.
park_key: illogical.crypt.Key = @splat(0),
park_config: illogical.park.Config = .{},
listener: sys.fd_t = -1,

/// One thread watching the descriptors of every terminal nobody is judging.
///
/// This is the cold half of docs/ARCHITECTURE.md's IO model, and it is what
/// makes ten thousand terminals a count of file descriptors rather than a
/// count of kernel threads. Terminals move in and out of it on the maintenance
/// tick; see `applyRegime`.
pty_poller: illogical.poller.Poller,

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
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .socket_path = try gpa.dupe(u8, socket_path),
        .store = .{ .root = try gpa.dupe(u8, state_root) },
        .pty_poller = try .init(gpa),
    };

    // The park key, generated on first run. Held here and pointed at by the
    // store, so it is not thirty-two bytes per terminal.
    //
    // A failure is loud but not fatal. A daemon that refuses to start because
    // it could not write a key file is worse than one that parks in plaintext
    // and says so plainly -- but it does have to say so, because the whole
    // reason F3 exists is that scrollback holds secrets.
    std.Io.Dir.cwd().createDirPath(io, state_root) catch {};
    var key_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (self.store.keyPath(&key_buf)) |key_path| {
        if (illogical.crypt.loadOrCreateKey(io, key_path)) |key| {
            self.park_key = key;
            self.store.key = &self.park_key;
        } else |err| {
            log.err("no park key ({t}); park files will be plaintext", .{err});
        }
    } else |_| {}

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

    // Same reasoning as the clients above: `Terminal.destroy` takes the
    // poller's dispatch lock to unregister, and a callback already running
    // there wants this terminal's own lock.
    self.mutex.lock();
    var terminals = self.terminals;
    self.terminals = .empty;
    var sessions = self.sessions;
    self.sessions = .empty;
    self.mutex.unlock();

    for (terminals.values()) |t| t.destroy();
    terminals.deinit(self.gpa);
    for (sessions.values()) |*s| s.deinit(self.gpa);
    sessions.deinit(self.gpa);

    // After every terminal has left it, so nothing is mid-dispatch.
    self.pty_poller.deinit();

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
    // A daemon that is already accepting on this socket owns every terminal
    // behind it, and the unlink below would take its socket away without
    // taking its terminals: two daemons, one of them unreachable, and a
    // client's session list quietly missing half of itself.
    //
    // This matters now because auto-starting is on a hot path. `illogicald
    // --stdio` starts a daemon whenever it cannot connect to one, so two SSH
    // connections arriving together on a machine with no daemon both try. A
    // probe closes that: it is not a lock, and two daemons could still pass
    // each other inside the microsecond between this and `bind`, but the case
    // it does cover is the one that actually happens.
    if (sys.connectUnix(self.socket_path)) |probe| {
        sys.closeFd(probe);
        return error.AlreadyRunning;
    } else |_| {}

    // A stale socket from a *crashed* daemon, which nothing answers on, would
    // make bind fail.
    cwd.deleteFile(self.io, self.socket_path) catch {};

    const addr = try sys.unixAddr(self.socket_path);
    const fd = try sys.unixSocket();
    errdefer sys.closeFd(fd);
    try sys.bindUnix(fd, &addr);
    try sys.listenFd(fd, 64);
    self.listener = fd;
    self.running.store(true, .release);
    try self.pty_poller.start();
    self.maintenance = try std.Thread.spawn(.{ .stack_size = Terminal.maintenance_stack_size }, maintenanceLoop, .{self});
    log.info("listening on {s}", .{self.socket_path});
}

/// Periodic housekeeping: park idle terminals, give live ones a bounded slice
/// of scrollback compression, and move each PTY into the IO regime it now
/// belongs in. See docs/PARKING.md.
pub fn maintenanceTick(self: *Server) void {
    self.retireExited();
    self.retireClients();
    self.parkClientBuffers();

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
        // First: a child that hung up while its PTY was polled is waiting for
        // somebody with a thread to spare to reap it.
        t.collectExit();

        const summary = t.summary();
        if (summary.residency == .exited) continue;

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

        self.applyRegime(t);
    }
}

/// Put one terminal's PTY in the regime it belongs in now (A3, level 2).
///
/// Read after the parking above rather than from the summary taken before it:
/// a terminal that just parked has no state left in memory to feed, and should
/// give up its thread on this tick rather than the next.
fn applyRegime(self: *Server, t: *Terminal) void {
    const want: Terminal.Regime = switch (illogical.park.ptyRegime(
        self.park_config,
        t.summary().residency,
        t.attachedCount(),
        t.unobservedNs(),
    )) {
        .hot => .hot,
        .polled => .polled,
    };
    if (t.currentRegime() == want) return;
    t.setRegime(want);
}

fn maintenanceLoop(self: *Server) void {
    while (self.running.load(.acquire)) {
        sys.sleepNs(250 * std.time.ns_per_ms);
        self.maintenanceTick();
    }
}

pub fn stop(self: *Server) void {
    if (!self.running.swap(false, .acq_rel)) return;
    // Before the terminals are torn down, so no callback is in flight while
    // one of them is unregistering.
    self.pty_poller.stop();
    if (self.listener >= 0) {
        // `shutdown` first, and it is the line that actually ends `run`.
        // Closing the descriptor does not wake a thread already blocked in
        // `accept` on Linux: the sleeping call holds its own reference to the
        // socket, so it keeps waiting for a connection that is never coming
        // while the descriptor number goes away underneath it. `stop` returned
        // anyway and every `join` behind it hung forever -- the two tests that
        // run a server on a thread of its own never finished, and `zig build
        // test` sat there with nothing printed until CI killed it at six
        // hours. Darwin happens to end the `accept` on `close`, which is why
        // only the Linux leg ever showed it.
        //
        // Same reasoning as `Client.destroy`, and the same tool; see
        // `sys.shutdownFd`. The woken `accept` fails, `run` breaks out of its
        // loop, and the close below is then just a close.
        sys.shutdownFd(self.listener);
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

/// Free the pipeline buffers of clients that have gone quiet. Level 3 of
/// docs/PARKING.md; the work itself is in `Client.parkBuffers`.
///
/// Under `clients_mutex`, which is only safe because `parkBuffers` never
/// blocks: it sets a flag for the writer thread and tries the read lock. One
/// busy connection must not hold up the tick for every other client.
fn parkClientBuffers(self: *Server) void {
    self.clients_mutex.lock();
    defer self.clients_mutex.unlock();
    for (self.clients.items) |c| c.parkBuffers(self.park_config);
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

    const default_argv = defaultArgv();
    const argv: []const []const u8 = if (req.argv.len > 0) req.argv else &default_argv;

    // A terminal always has a working directory, because clients label tabs
    // with it. Fall back to the user's home rather than reporting nothing.
    const cwd = req.cwd orelse sys.getenv("HOME") orelse "/";

    const t = try Terminal.create(self.gpa, .{
        .io = self.io,
        .store = self.store,
        .park_config = self.park_config,
        .poller = &self.pty_poller,
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
            .regime = sum.regime,
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

/// What a terminal runs when the client named no command: the user's shell, as
/// a **login** shell.
///
/// The `-l` is the whole of this function, and it is not a nicety. Every child
/// inherits the daemon's environment, and where the daemon got that
/// environment depends entirely on who started it. Started from a terminal it
/// already has a full interactive PATH and nothing here is visible. Started by
/// the Mac app -- which is now the ordinary case, not the exotic one -- it
/// inherits launchd's GUI environment, where PATH is
/// `/usr/bin:/bin:/usr/sbin:/sbin` and that is all. A non-login shell reads
/// neither `/etc/zprofile` (where `path_helper` runs) nor `~/.zprofile`, so
/// every terminal in the app would open with no brew, no `~/.cargo/bin`, and
/// nothing else the user installed -- a first-run experience of "where is
/// everything?".
///
/// This is the same class of problem `pty.zig` already fixes for LANG, and it
/// is fixed the same way: repair what a GUI launch failed to provide, using
/// the configuration the user already has rather than guessing at paths.
/// Terminal.app and Ghostty both spawn login shells for exactly this reason,
/// which is why a shell opened there has a working PATH and one opened from a
/// GUI subprocess does not.
///
/// `-l` is understood by sh, bash, zsh, fish, nushell and tcsh. It is not
/// imposed on anyone: a client that wants something else -- `illogical new --
/// htop`, or a non-login shell -- names it in `create.argv`, which this does
/// not touch.
fn defaultArgv() [2][]const u8 {
    return .{ defaultShell(), "-l" };
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

test "a second daemon on one socket refuses to start, and leaves the first alone" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sock_buf: [96]u8 = undefined;
    const sock_path = try std.fmt.bufPrintZ(
        &sock_buf,
        "/tmp/illogical-second-{d}.sock",
        .{std.c.getpid()},
    );
    defer sys.unlinkPath(sock_path.ptr);

    var state_buf: [96]u8 = undefined;
    const state_root = try std.fmt.bufPrint(
        &state_buf,
        "/tmp/illogical-second-state-{d}",
        .{std.c.getpid()},
    );
    defer std.Io.Dir.cwd().deleteTree(io, state_root) catch {};

    const first = try Server.init(gpa, io, sock_path, state_root);
    defer first.deinit();
    try first.listen();
    const accepting = try std.Thread.spawn(.{}, Server.run, .{first});
    defer accepting.join();
    defer first.stop();

    // What `illogicald --stdio` does when two SSH connections race to
    // auto-start a daemon. Before the probe in `listen` this succeeded, and
    // the winner unlinked the loser's socket while every terminal behind it
    // stayed alive and unreachable.
    const second = try Server.init(gpa, io, sock_path, state_root);
    defer second.deinit();
    try testing.expectError(error.AlreadyRunning, second.listen());

    // The refusal is not enough on its own: the socket has to still lead to
    // the first daemon afterwards.
    const probe = try sys.connectUnix(sock_path);
    sys.closeFd(probe);
}

test "a terminal with no command of its own gets a login shell" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const pid = std.c.getpid();
    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/illogical-loginsh-{d}", .{pid});
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    var shell_buf: [160]u8 = undefined;
    const shell = try std.fmt.bufPrintZ(&shell_buf, "{s}/shell", .{root});
    var argv_buf: [160]u8 = undefined;
    const argv_file = try std.fmt.bufPrint(&argv_buf, "{s}/argv", .{root});

    // A stub $SHELL that writes down how it was invoked, because that is the
    // only way to observe it: `Terminal` records argv[0] and nothing else, and
    // a real shell's PATH is whatever this machine's dotfiles say.
    //
    // The shebang makes the kernel run `/bin/sh <shell> -l`, so `$1` here is
    // argv[1] as the daemon passed it. It then sleeps rather than exiting, so
    // the terminal is still alive when the assertion runs.
    var script_buf: [400]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &script_buf,
        "#!/bin/sh\nprintf '%s' \"$1\" > {s}\nsleep 30\n",
        .{argv_file},
    );
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = shell,
        .data = script,
        .flags = .{ .permissions = .executable_file },
    });

    // Process-wide, and restored below. `defaultShell` is the only reader of
    // SHELL in the daemon, and the tests in this binary all pass argv
    // explicitly, so nothing else can see this.
    const had_shell = sys.getenv("SHELL");
    var saved_buf: [512]u8 = undefined;
    const saved: ?[:0]const u8 = if (had_shell) |v|
        std.fmt.bufPrintZ(&saved_buf, "{s}", .{v}) catch null
    else
        null;
    sys.setenvVar("SHELL", shell.ptr);
    defer if (saved) |v| sys.setenvVar("SHELL", v.ptr);

    var sock_buf: [160]u8 = undefined;
    const sock_path = try std.fmt.bufPrintZ(&sock_buf, "{s}/server.sock", .{root});

    const server = try Server.init(gpa, io, sock_path, root);
    defer server.deinit();
    try server.listen();
    const accepting = try std.Thread.spawn(.{}, Server.run, .{server});
    defer accepting.join();
    defer server.stop();

    const created = try server.createTerminal(.{ .session_name = "login", .name = "one" });
    // `hangup` closes the PTY; the stub is sleeping, so kill its group too or
    // it outlives the suite by half a minute.
    defer server.killTerminal(created.terminal, 9) catch {};
    defer server.killTerminal(created.terminal, 0) catch {};

    var waited: usize = 0;
    while (waited < 5000) : (waited += 10) {
        if (std.Io.Dir.cwd().access(io, argv_file, .{})) |_| break else |_| {}
        sys.sleepNs(10 * std.time.ns_per_ms);
    } else return error.ShellNeverRan;

    const recorded = try std.Io.Dir.cwd().readFileAlloc(io, argv_file, gpa, .limited(64));
    defer gpa.free(recorded);
    // The line that gives an app-started daemon a PATH. Without it every
    // terminal the Mac app opens has launchd's four directories in PATH and
    // nothing the user ever installed.
    try testing.expectEqualStrings("-l", recorded);
}
