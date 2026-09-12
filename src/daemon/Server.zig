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

    // Whether any terminal's breadcrumb moved on this tick. One broadcast for
    // all of them: `sessions_changed` sends every client back for a whole
    // `list`, and a tick where four terminals changed directory is still one
    // thing that happened.
    var breadcrumbs_moved = false;

    for (ids.items) |id| {
        const t = self.terminal(id) orelse continue;
        // First: a child that hung up while its PTY was polled is waiting for
        // somebody with a thread to spare to reap it.
        t.collectExit();

        const summary = t.summary();
        if (summary.residency == .exited) continue;

        // Where the child is and what it is running. Before the parking
        // below, which does not care either way -- a probe touches none of the
        // clocks parking reads, and a parked terminal's child is as alive and
        // as askable as a hot one's.
        if (t.probeForeground()) breadcrumbs_moved = true;

        if (illogical.park.shouldPark(
            self.park_config,
            summary.residency,
            summary.pty_read_idle_ns,
            // Not on the summary: it is a scheduling detail of this tick, and
            // the summary is what `illogical list` prints.
            t.wakeIdleNs(),
            summary.attached,
        )) {
            t.park() catch |err| log.warn("terminal {d} failed to park: {t}", .{ id, err });
        } else if (summary.residency == .live) {
            t.compressStep();
        }

        self.applyRegime(t);
    }

    // Outside the loop and outside the registry lock, like every other
    // broadcast on this tick.
    if (breadcrumbs_moved) self.notifySessionsChanged();
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
    // Sessions the sweep below emptied out of existence. This is the *only*
    // place a session's `meta.json` is discarded, which is what keeps the
    // file's lifetime identical to the registry entry's: written when the
    // session is created or renamed, removed exactly when it stops existing.
    // Discarded outside the lock, with the terminals' park files.
    var dropped: std.ArrayList(session.Id) = .empty;
    defer dropped.deinit(self.gpa);

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
            dropped.append(self.gpa, sid) catch {};
        }
    }

    for (retired.items) |t| {
        log.info("terminal {d} exited, retiring", .{t.id});
        t.store.discard(self.io, t.id);
        t.destroy();
    }
    // Nothing is going to rebuild a session that no longer exists, so its name
    // has no business outliving it. Named files only, never the directory
    // wholesale: see `park.Store.discardSessionMeta`.
    for (dropped.items) |sid| self.store.discardSessionMeta(self.io, sid);

    // One broadcast, on the tick that does both. On every path reachable
    // today `dropped` is non-empty only when `retired` is -- the loop above is
    // the only thing that empties a session, and both loops share this one
    // critical section -- so the OR never fires on its own and a client hears
    // about the retirement and the session's disappearance together.
    //
    // It is written as "did the list change" rather than `retired.len == 0`
    // anyway, because that invariant lives two loops away: a future path that
    // empties a session without retiring a terminal on the same tick (pruning
    // the registry directly, moving a terminal between sessions) would
    // silently stop announcing itself.
    if (retired.items.len == 0 and dropped.items.len == 0) return;
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
    self.persistSessionName(id, name);
    return id;
}

/// Write a session's name to its `meta.json`.
///
/// Best effort on purpose. A name that did not reach disk is a session that
/// forgets its label across a daemon restart -- worth a line in the log, and
/// not worth refusing to open a terminal or rejecting a rename the registry
/// has already accepted.
///
/// Both callers hold `mutex`, so this is filesystem work under the registry
/// lock. That is not new: `createTerminal` already forks a child and opens a
/// PTY there, and this is one small write beside it. It stays inside the lock
/// because the alternative is a window in which the registry and the file
/// disagree about a session's name.
fn persistSessionName(self: *Server, id: session.Id, name: []const u8) void {
    self.store.writeSessionMeta(self.io, id, name) catch |err|
        log.warn("session {d}: meta.json not written: {t}", .{ id, err });
}

/// Rename a session.
///
/// A pure relabelling: the id is what terminals, clients and tabs key on, so
/// nothing moves and no client loses a tab. The caller broadcasts
/// `sessions_changed` afterwards, outside the registry lock -- the same shape
/// `create` uses.
pub fn renameSession(self: *Server, id: session.Id, name: []const u8) !void {
    try session.validateName(name);

    self.mutex.lock();
    defer self.mutex.unlock();

    const s = self.sessions.getPtr(id) orelse return error.NoSuchSession;
    // Renaming a session to the name it already has is a success with nothing
    // to do -- not an error, and not a write.
    if (std.mem.eql(u8, s.name, name)) return;

    // Exact match, mirroring `sessionByNameLocked`. Names are how `create`
    // finds a session, so two sessions sharing one would make which terminal
    // lands where a question of iteration order.
    for (self.sessions.values()) |other| {
        if (std.mem.eql(u8, other.name, name)) return error.NameInUse;
    }

    const dup = try self.gpa.dupe(u8, name);
    self.gpa.free(s.name);
    s.name = dup;

    self.persistSessionName(id, name);
    log.info("session {d} renamed to {s}", .{ id, name });
}

/// What `deleteSession` does with a session that would still kill something.
pub const DeleteMode = enum {
    /// Close every terminal in it. What the app does, behind a confirmation.
    cascade,
    /// Refuse, with `error.SessionBusy`, if any child is still running. So a
    /// script can be careful.
    only_if_empty,
};

/// Delete a session: close its terminals and drop it from the registry.
///
/// Nothing is torn down here. Each terminal is hung up and then goes the way
/// every closed terminal goes -- child exit, then `retireExited` on the
/// maintenance tick, which discards its park state, drops the emptied session,
/// discards its `meta.json` and broadcasts `sessions_changed`. A session that
/// was already empty is dropped by that same sweep. Forcing it here would mean
/// joining a terminal's reader thread from a client's dispatch, which is
/// exactly why retirement lives on the tick in the first place.
///
/// So the session row survives this call by a maintenance tick or two, and a
/// child that ignores SIGHUP lingers exactly as a killed terminal does today.
///
/// Nothing on disk is touched here either, and that is the point: `meta.json`
/// is discarded by the sweep that drops the registry entry and nowhere else,
/// so the file and the registry cannot disagree. Discarding it on acceptance
/// would leave a nameless session behind for as long as a stubborn child took
/// to die -- and would delete the name out from under a `create` that landed
/// in that same window and reused the session.
pub fn deleteSession(self: *Server, id: session.Id, mode: DeleteMode) !void {
    var ids: std.ArrayList(session.TerminalId) = .empty;
    defer ids.deinit(self.gpa);

    {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.sessions.getPtr(id) orelse return error.NoSuchSession;

        // "Empty" means "would kill nothing", not "has no registry entries".
        //
        // A terminal is removed from `s.terminals` by the maintenance sweep,
        // not by its child exiting, so a session whose last child exited is
        // still listed for up to a tick. Counting entries would refuse
        // precisely the state a careful script is in -- everything has exited,
        // retirement is pending -- and a genuinely empty session is swept out
        // of existence within that same tick, so there would be almost nothing
        // left for the flag to succeed on. `finished` is the flag retirement
        // itself keys on, so the two cannot disagree about which it is.
        if (mode == .only_if_empty) {
            for (s.terminals.items) |tid| {
                const t = self.terminals.get(tid) orelse continue;
                if (!t.finished.load(.acquire)) return error.SessionBusy;
            }
        }

        try ids.appendSlice(self.gpa, s.terminals.items);
    }

    // Outside the registry lock: `killTerminal` takes it again to look the
    // terminal up. Failures are ignored one at a time -- a terminal that
    // retired between the copy above and here is one fewer thing to close.
    for (ids.items) |tid| self.killTerminal(tid, 0) catch {};

    log.info("session {d} deleted ({d} terminal(s) closing)", .{ id, ids.items.len });
}

pub const CreateResult = struct {
    terminal: session.TerminalId,
    session: session.Id,
};

pub fn createTerminal(self: *Server, req: protocol.body.Create) !CreateResult {
    // Before the lock, and before anything is spawned. `create` is the only
    // way into the registry besides `rename`, and a registry that accepted
    // names the rename path refuses would be indefensible on its own -- quite
    // apart from what unvalidated wire bytes do to `writeSessionMeta`, which
    // now puts every session name on disk.
    //
    // The *terminal* name is deliberately not checked. It never reaches disk,
    // and refusing it would break `illogical new -n "my name"` for no gain;
    // the rule for terminal names belongs with terminal rename (#38).
    try session.validateName(req.session_name);

    // Also before the lock, and for a sharper reason than the name check: this
    // is a syscall on a path a *client* chose. `access` on a wedged network
    // mount blocks uninterruptibly, and under the registry lock that would
    // stall every other client's `list`, `create` and `kill` -- and the
    // maintenance tick with them -- on one dead NFS server. Nothing here reads
    // the registry, so it has no business holding it.
    //
    // A terminal always has a working directory, because clients label tabs
    // with it. Fall back to the user's home rather than reporting nothing.
    //
    // A directory that cannot be entered counts as no directory at all, which
    // is Ghostty's rule too ("cannot access cwd, ignoring", `termio/Exec.zig`).
    // The Mac app sends the directory of the terminal a new one was made from,
    // and that can be a worktree removed since. The child's `chdir` fails
    // silently, so without this the shell would start wherever the daemon
    // itself stands -- `/` when it is detached, the checkout for `just serve`
    // -- under a label naming the directory it is not in. `$HOME` is checked
    // the same way rather than trusted: a daemon whose home is gone or
    // unmounted would otherwise hand the child a path that fails identically.
    const cwd = cwd: {
        if (req.cwd) |dir| if (sys.isEnterableDir(dir)) break :cwd dir;
        const home = sys.getenv("HOME") orelse "";
        if (sys.isEnterableDir(home)) break :cwd home;
        break :cwd "/";
    };

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
        // Copied under the terminal's own lock rather than borrowed off the
        // summary: the maintenance tick rewrites both while this runs on a
        // client's thread. See `Terminal.label`.
        const crumb = try t.label(arena);
        try terms.append(arena, .{
            .id = sum.id,
            .session = sum.session,
            .name = try arena.dupe(u8, sum.name),
            .command = crumb.command,
            .cwd = crumb.cwd,
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

/// A daemon on a socket and a state directory of its own.
///
/// The same shape as the two tests below, which spell it out inline; a struct
/// because the session-lifecycle tests need four of them and the setup is
/// twenty lines of paperwork each. Heap-allocated so `threaded` does not move:
/// the server holds the `std.Io` it hands out.
const TestDaemon = struct {
    gpa: Allocator,
    threaded: std.Io.Threaded,
    server: *Server = undefined,
    accepting: std.Thread = undefined,
    root_buf: [96]u8 = undefined,
    root: []const u8 = &.{},
    sock_buf: [160]u8 = undefined,

    fn start(gpa: Allocator, tag: []const u8) !*TestDaemon {
        const self = try gpa.create(TestDaemon);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .threaded = .init(gpa, .{}) };
        errdefer self.threaded.deinit();

        const cwd_io = self.threaded.io();
        self.root = try std.fmt.bufPrint(
            &self.root_buf,
            "/tmp/illogical-{s}-{d}",
            .{ tag, std.c.getpid() },
        );
        std.Io.Dir.cwd().deleteTree(cwd_io, self.root) catch {};
        try std.Io.Dir.cwd().createDirPath(cwd_io, self.root);

        const sock = try std.fmt.bufPrintZ(&self.sock_buf, "{s}/server.sock", .{self.root});
        self.server = try Server.init(gpa, cwd_io, sock, self.root);
        errdefer self.server.deinit();
        // `listen` is what starts the PTY poller and the maintenance thread,
        // and retirement lives on that thread -- so the delete tests wait for
        // it rather than ticking by hand and racing it.
        try self.server.listen();
        self.accepting = try std.Thread.spawn(.{}, Server.run, .{self.server});
        return self;
    }

    fn io(self: *TestDaemon) std.Io {
        return self.threaded.io();
    }

    /// Everything the test created, in the order that does not hang.
    fn stop(self: *TestDaemon) void {
        // The stub children sleep; `Terminal.destroy` closes the PTY master
        // but does not signal, so kill the groups outright or they outlive the
        // suite. Same reasoning as the login-shell test below.
        self.server.mutex.lock();
        var ids: std.ArrayList(session.TerminalId) = .empty;
        ids.appendSlice(self.gpa, self.server.terminals.keys()) catch {};
        self.server.mutex.unlock();
        for (ids.items) |id| self.server.killTerminal(id, 9) catch {};
        ids.deinit(self.gpa);

        self.server.stop();
        self.accepting.join();
        self.server.deinit();
        std.Io.Dir.cwd().deleteTree(self.threaded.io(), self.root) catch {};
        self.threaded.deinit();
        self.gpa.destroy(self);
    }

    /// A terminal running a child that does nothing and exits on SIGHUP.
    fn spawnIdle(self: *TestDaemon, session_name: []const u8, name: []const u8) !CreateResult {
        return self.server.createTerminal(.{
            .session_name = session_name,
            .name = name,
            .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        });
    }

    /// A terminal whose child exits at once, of its own accord. What a person
    /// typing `exit` produces, which is the ordinary way a session ends.
    fn spawnExiting(self: *TestDaemon, session_name: []const u8, name: []const u8) !CreateResult {
        return self.server.createTerminal(.{
            .session_name = session_name,
            .name = name,
            .argv = &.{ "/bin/sh", "-c", ":" },
        });
    }

    /// The name `list` reports for `id`, or null if it lists no such session.
    fn sessionName(self: *TestDaemon, arena: Allocator, id: session.Id) !?[]const u8 {
        const list = try self.server.listInto(arena);
        for (list.sessions) |s| {
            if (s.id == id) return s.name;
        }
        return null;
    }

    /// The `name` field of a session's `meta.json`, or null if there is none.
    fn persistedName(self: *TestDaemon, gpa: Allocator, id: session.Id) !?[]u8 {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try self.server.store.sessionMetaPath(&path_buf, id);
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io(),
            path,
            gpa,
            .limited(4096),
        ) catch return null;
        defer gpa.free(bytes);
        const parsed = try std.json.parseFromSlice(
            illogical.park.Store.SessionMeta,
            gpa,
            bytes,
            .{},
        );
        defer parsed.deinit();
        return try gpa.dupe(u8, parsed.value.name);
    }
};

test "a terminal that moves is followed by the list, on the tick" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const d = try TestDaemon.start(gpa, "crumbs");
    defer d.stop();

    const made = try d.server.createTerminal(.{
        .session_name = "work",
        .name = "1",
        // Moves, says one thing, and stays. The order is what makes this
        // deterministic rather than a race: the probe is gated on output, and
        // the byte that opens the gate is written from a process that has
        // already arrived. A person at a prompt is the same shape -- the
        // prompt they are looking at was printed after the `cd` returned.
        .argv = &.{ "/bin/sh", "-c", "cd /usr; printf .; sleep 30" },
    });

    // Nothing here drives the probe: the maintenance thread does it, on its
    // own clock, which is the path the Mac client actually gets this on.
    var waited: usize = 0;
    while (waited < 5000) : (waited += 10) {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const list = try d.server.listInto(arena.allocator());
        for (list.terminals) |t| {
            if (t.id != made.terminal) continue;
            // Not the command as well: `/bin/sh` is Apple's `sh` on one
            // platform and a symlink to `dash` on the other, and what comes
            // back is the name of the executable. The command half is pinned
            // in `Terminal.zig`, against a binary that is called the same
            // thing everywhere.
            if (std.mem.eql(u8, t.cwd, "/usr")) return;
        }
        sys.sleepNs(10 * std.time.ns_per_ms);
    }
    return error.ListNeverMoved;
}

test "a create whose directory cannot be entered starts at home" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const d = try TestDaemon.start(gpa, "gone-cwd");
    defer d.stop();

    const kept = try d.server.createTerminal(.{
        .session_name = "work",
        .name = "kept",
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .cwd = "/usr",
    });
    // The worktree the terminal it was made from was standing in, removed.
    const gone = try d.server.createTerminal(.{
        .session_name = "work",
        .name = "gone",
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .cwd = "/illogical-no-such-directory",
    });
    // There, and still not somewhere a child can stand. An existence check
    // passes this one through to a `chdir` that fails silently, which is the
    // whole difference between `F_OK` and the `X_OK` the spawn actually needs.
    // `/etc/hosts` carries no execute bit on either platform, so it fails for
    // root as well.
    const file = try d.server.createTerminal(.{
        .session_name = "work",
        .name = "file",
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .cwd = "/etc/hosts",
    });

    // Read off the label rather than the child. The probe gate starts shut and
    // `sleep` never opens it, so the list reports exactly the directory
    // `createTerminal` chose to spawn in -- which is the decision under test,
    // with no tick to wait for.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const list = try d.server.listInto(arena.allocator());
    const home = sys.getenv("HOME") orelse "/";
    var seen: usize = 0;
    for (list.terminals) |t| {
        if (t.id == kept.terminal) {
            try testing.expectEqualStrings("/usr", t.cwd);
            seen += 1;
        }
        if (t.id == gone.terminal or t.id == file.terminal) {
            try testing.expectEqualStrings(home, t.cwd);
            seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "renaming a session is validated, persisted, and visible in the list" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const daemon = try TestDaemon.start(gpa, "rename");
    defer daemon.stop();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const created = try daemon.spawnIdle("work", "one");

    // The name is on disk from the moment the session exists, not only after a
    // rename: `meta.json` is what a restart would rebuild the registry from.
    {
        const persisted = try daemon.persistedName(gpa, created.session);
        defer if (persisted) |p| gpa.free(p);
        try testing.expectEqualStrings("work", persisted orelse return error.NoSessionMeta);
    }

    try daemon.server.renameSession(created.session, "done");

    try testing.expectEqualStrings(
        "done",
        (try daemon.sessionName(arena, created.session)) orelse return error.SessionGone,
    );
    {
        const persisted = try daemon.persistedName(gpa, created.session);
        defer if (persisted) |p| gpa.free(p);
        try testing.expectEqualStrings("done", persisted orelse return error.NoSessionMeta);
    }

    // The id is what everything keys on, so the terminal is where it was and
    // still says so -- that is the whole property issue #37 asks to audit.
    const list = try daemon.server.listInto(arena);
    try testing.expectEqual(@as(usize, 1), list.terminals.len);
    try testing.expectEqual(created.session, list.terminals[0].session);
    try testing.expectEqual(created.terminal, list.terminals[0].id);
}

test "a rename is refused when the name is bad, taken, or names no session" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const daemon = try TestDaemon.start(gpa, "rename-refuse");
    defer daemon.stop();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = try daemon.spawnIdle("work", "one");
    const second = try daemon.spawnIdle("other", "two");
    try testing.expect(first.session != second.session);

    const server = daemon.server;
    try testing.expectError(error.NameEmpty, server.renameSession(first.session, ""));
    try testing.expectError(
        error.NameInvalidChar,
        server.renameSession(first.session, "has space"),
    );
    try testing.expectError(
        error.NameInvalidChar,
        server.renameSession(first.session, "../escape"),
    );
    try testing.expectError(
        error.NameTooLong,
        server.renameSession(first.session, "x" ** (session.max_name_len + 1)),
    );
    // Taken by the other session. Names are how `create` finds a session, so
    // two of them sharing one would decide by iteration order which terminal
    // lands where.
    try testing.expectError(error.NameInUse, server.renameSession(first.session, "other"));
    try testing.expectError(error.NoSuchSession, server.renameSession(9999, "anything"));

    // Renaming a session to what it is already called is a success that does
    // nothing -- the client should not have to check first.
    try server.renameSession(first.session, "work");

    try testing.expectEqualStrings(
        "work",
        (try daemon.sessionName(arena, first.session)) orelse return error.SessionGone,
    );
    const persisted = try daemon.persistedName(gpa, first.session);
    defer if (persisted) |p| gpa.free(p);
    try testing.expectEqualStrings("work", persisted orelse return error.NoSessionMeta);
}

test "deleting a session cascades, and takes its meta and its park files with it" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const daemon = try TestDaemon.start(gpa, "delete-cascade");
    defer daemon.stop();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Park immediately, so both terminals have a file on disk to lose. It is
    // also the case that makes R1 real: session 1's `meta.json` and terminal
    // 1's `snapshot.gsnp` land in the same `sessions/1/` directory.
    daemon.server.park_config.park_after_ns = 0;

    const one = try daemon.spawnIdle("doomed", "a");
    const two = try daemon.spawnIdle("doomed", "b");
    try testing.expectEqual(one.session, two.session);

    const io = daemon.io();
    const store = daemon.server.store;
    var waited: usize = 0;
    while (waited < 10_000) : (waited += 10) {
        if (store.snapshotSize(io, one.terminal) != null and
            store.snapshotSize(io, two.terminal) != null) break;
        sys.sleepNs(10 * std.time.ns_per_ms);
    } else return error.TerminalsNeverParked;

    try daemon.server.deleteSession(one.session, .cascade);

    // Accepting the delete changes nothing on disk. The name belongs to the
    // registry entry and goes when *that* goes, not when the request is
    // accepted -- otherwise a session whose child ignores SIGHUP sits in the
    // list with no name behind it, and a `create` landing in that window
    // reuses a session whose meta was just deleted.
    {
        const persisted = try daemon.persistedName(gpa, one.session);
        defer if (persisted) |p| gpa.free(p);
        try testing.expectEqualStrings("doomed", persisted orelse return error.NoSessionMeta);
    }
    // ...and terminal 1's park file, in that same directory, is untouched too.
    // The terminals themselves are still on their way out.
    try testing.expect(store.snapshotSize(io, one.terminal) != null);

    // The rest is the ordinary retirement path on the maintenance tick, which
    // `listen` is already running: SIGHUP, child exit, park state discarded,
    // the emptied session dropped, its meta discarded, `sessions_changed`.
    //
    // Every condition in one wait, and deliberately: `retireExited` takes the
    // terminals out of the registry under the lock and touches the filesystem
    // after releasing it, so there is an instant where `list` is empty and the
    // files are still there. Waiting on the list alone made this assertion
    // fail about one run in ten.
    waited = 0;
    while (waited < 10_000) : (waited += 10) {
        _ = arena_state.reset(.retain_capacity);
        const persisted = try daemon.persistedName(gpa, one.session);
        defer if (persisted) |p| gpa.free(p);
        if ((try daemon.sessionName(arena, one.session)) == null and
            persisted == null and
            store.snapshotSize(io, one.terminal) == null and
            store.snapshotSize(io, two.terminal) == null) break;
        sys.sleepNs(10 * std.time.ns_per_ms);
    } else return error.SessionNeverWentAway;

    _ = arena_state.reset(.retain_capacity);
    const list = try daemon.server.listInto(arena);
    try testing.expectEqual(@as(usize, 0), list.terminals.len);
    try testing.expectEqual(@as(usize, 0), list.sessions.len);

    // Nothing is left in the state directory either: both discards reap the
    // directory they emptied.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try store.sessionDir(&dir_buf, one.session);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dir, .{}));
}

test "a session that empties on its own loses its meta.json with it" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const daemon = try TestDaemon.start(gpa, "natural-exit");
    defer daemon.stop();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The ordinary way a session ends: nobody deletes it, the last child just
    // exits. `deleteSession` is not involved at all, so retirement's sweep is
    // the only thing that can discard the name -- which is the point. Without
    // this the daemon leaks one `meta.json` per session for the life of the
    // machine, and every other test here still passes.
    const created = try daemon.spawnExiting("transient", "one");

    var waited: usize = 0;
    while (waited < 10_000) : (waited += 10) {
        _ = arena_state.reset(.retain_capacity);
        const persisted = try daemon.persistedName(gpa, created.session);
        defer if (persisted) |p| gpa.free(p);
        if ((try daemon.sessionName(arena, created.session)) == null and persisted == null) break;
        sys.sleepNs(10 * std.time.ns_per_ms);
    } else return error.SessionMetaOutlivedTheSession;

    _ = arena_state.reset(.retain_capacity);
    const list = try daemon.server.listInto(arena);
    try testing.expectEqual(@as(usize, 0), list.sessions.len);
    try testing.expectEqual(@as(usize, 0), list.terminals.len);
}

test "an only-if-empty delete refuses a session that still has terminals" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const daemon = try TestDaemon.start(gpa, "delete-busy");
    defer daemon.stop();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const created = try daemon.spawnIdle("busy", "one");

    try testing.expectError(
        error.SessionBusy,
        daemon.server.deleteSession(created.session, .only_if_empty),
    );
    try testing.expectError(
        error.NoSuchSession,
        daemon.server.deleteSession(9999, .cascade),
    );

    // Refused means nothing happened: the session, its terminal and its name
    // on disk are all where they were.
    try testing.expectEqualStrings(
        "busy",
        (try daemon.sessionName(arena, created.session)) orelse return error.SessionGone,
    );
    const list = try daemon.server.listInto(arena);
    try testing.expectEqual(@as(usize, 1), list.terminals.len);
    const persisted = try daemon.persistedName(gpa, created.session);
    defer if (persisted) |p| gpa.free(p);
    try testing.expectEqualStrings("busy", persisted orelse return error.NoSessionMeta);
}

test "an only-if-empty delete accepts a session whose children have all exited" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/illogical-ifempty-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    var sock_buf: [160]u8 = undefined;
    const sock = try std.fmt.bufPrintZ(&sock_buf, "{s}/server.sock", .{root});

    // No `listen`, and that is the whole design of this test: the maintenance
    // thread is what removes an exited terminal from its session, so with one
    // running the window this asserts on closes within 250 ms and the test
    // becomes a race. Without it the window is held open indefinitely.
    const server = try Server.init(gpa, io, sock, root);
    defer server.deinit();

    // Two terminals in one session, and the refusal is asserted against the
    // one that keeps running. A child that exits *needs no maintenance thread
    // to be noticed* -- its terminal's own reader hits EOF and sets `finished`
    // within a millisecond or two -- so asserting `SessionBusy` against a
    // just-spawned `sh -c ':'` is a race, and a measured one: an inserted 3 ms
    // delay is enough to lose it. The sleeper holds the busy leg open for as
    // long as the test needs.
    const busy = try server.createTerminal(.{
        .session_name = "brief",
        .name = "sleeper",
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
    });
    defer server.killTerminal(busy.terminal, 9) catch {};
    const brief = try server.createTerminal(.{
        .session_name = "brief",
        .name = "one",
        .argv = &.{ "/bin/sh", "-c", ":" },
    });
    try testing.expectEqual(busy.session, brief.session);

    // One running child is enough to refuse, whatever the other one is doing.
    try testing.expectError(
        error.SessionBusy,
        server.deleteSession(busy.session, .only_if_empty),
    );

    // Now let the short-lived one go, and hang up the sleeper so that both
    // children are finished. No maintenance thread is running, so nothing
    // removes either terminal from the session: the window this asserts on
    // stays open until the test closes it.
    const short = server.terminal(brief.terminal) orelse return error.NoTerminal;
    const sleeper = server.terminal(busy.terminal) orelse return error.NoTerminal;
    server.killTerminal(busy.terminal, 9) catch {};

    var waited: usize = 0;
    while (waited < 10_000) : (waited += 10) {
        if (short.finished.load(.acquire) and sleeper.finished.load(.acquire)) break;
        sys.sleepNs(10 * std.time.ns_per_ms);
    } else return error.ChildrenNeverExited;

    // Both still listed -- nothing has swept them -- but there is nothing left
    // to kill, which is the only state a careful script can actually observe.
    // Counting registry entries would refuse here, and a genuinely empty
    // session is swept out of existence within a tick, so a `len == 0` check
    // leaves the flag with essentially nothing it can ever succeed on.
    server.mutex.lock();
    const still_listed = server.sessions.getPtr(busy.session).?.terminals.items.len;
    server.mutex.unlock();
    try testing.expectEqual(@as(usize, 2), still_listed);

    try server.deleteSession(busy.session, .only_if_empty);
}

test "a create with a name the server would refuse spawns nothing" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/illogical-badcreate-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    var sock_buf: [160]u8 = undefined;
    const sock = try std.fmt.bufPrintZ(&sock_buf, "{s}/server.sock", .{root});

    // No `listen`: validation happens before the lock and before anything is
    // spawned, so nothing here ever needs a poller or a PTY.
    const server = try Server.init(gpa, io, sock, root);
    defer server.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `create` is the other way into the registry, and until this existed it
    // took raw wire bytes: a session named with a space was accepted here and
    // then refused by `rename`, and the name went to `writeSessionMeta`
    // unchecked.
    try testing.expectError(
        error.NameInvalidChar,
        server.createTerminal(.{ .session_name = "has space" }),
    );
    try testing.expectError(
        error.NameEmpty,
        server.createTerminal(.{ .session_name = "" }),
    );
    try testing.expectError(
        error.NameTooLong,
        server.createTerminal(.{ .session_name = "x" ** (session.max_name_len + 1) }),
    );
    try testing.expectError(
        error.NameInvalidChar,
        server.createTerminal(.{ .session_name = "../escape" }),
    );

    // Refused all the way down: no session, no terminal, no id consumed.
    const list = try server.listInto(arena);
    try testing.expectEqual(@as(usize, 0), list.sessions.len);
    try testing.expectEqual(@as(usize, 0), list.terminals.len);
    try testing.expectEqual(@as(session.Id, 1), server.next_session_id);
    try testing.expectEqual(@as(session.TerminalId, 1), server.next_terminal_id);

    // The *terminal* name is deliberately untouched by this rule: it never
    // reaches disk, and `illogical new -n "my name"` has always worked.
    const created = try server.createTerminal(.{
        .session_name = "fine",
        .name = "a name with spaces",
        .argv = &.{ "/bin/sh", "-c", ":" },
    });
    defer server.killTerminal(created.terminal, 9) catch {};
    _ = arena_state.reset(.retain_capacity);
    const after = try server.listInto(arena);
    try testing.expectEqual(@as(usize, 1), after.terminals.len);
    try testing.expectEqualStrings("a name with spaces", after.terminals[0].name);
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
