//! `illogicald --stdio` — the wire protocol on stdin and stdout.
//!
//! This is the remote transport, and it is deliberately a **bridge** rather
//! than a server. `ssh host illogicald --stdio` starts a process per
//! connection; a server started that way would die with the SSH session and
//! take every terminal in it, which is the one thing this project exists to
//! prevent. So the process SSH starts connects to the host's own long-lived
//! daemon — starting one, detached, if there is none — and copies bytes
//! between that socket and the pipe SSH gave it.
//!
//!     ssh dest illogicald --stdio
//!         stdin  ──►┐                     ┌──► daemon (unix socket)
//!                   │  bridge, two pumps  │
//!         stdout ◄──┘                     └──◄
//!
//! Nothing here parses a frame. The protocol is a byte stream over a reliable,
//! ordered transport, and a splice preserves it exactly — so the bridge cannot
//! desynchronize a client no matter what the two ends say to each other, and it
//! costs one copy rather than a decode and a re-encode.
//!
//! There is no authentication and no listening socket, by design: access is
//! whatever SSH decided, and the unix socket at the far end is filesystem
//! permissions. See docs/PROTOCOL.md, "Transport".

const std = @import("std");
const illogical = @import("illogical");
const sys = illogical.sys;

const log = std.log.scoped(.stdio);

/// One copy buffer, per direction. Four PTY reads (`Terminal.read_buf_size` is
/// 16 KiB), so an ordinary burst of output crosses the bridge in one read and
/// one write rather than four of each. Deliberately far below the 1 MiB
/// per-client output queue: this buffer is on a thread stack, and the queue it
/// feeds from is the thing allowed to be large.
const buf_size = 64 * 1024;

/// The upstream pump's stack. Its copy buffer lives on it.
const stack_size = 512 * 1024;

/// Signals sent a millisecond apart before backing off to 50 Hz, matching
/// `Terminal.stopReaderLocked` — a thread already parked in `read` needs one.
const interrupt_burst = 20;

pub const Options = struct {
    /// Start a daemon if nothing is listening on the socket. On by default,
    /// because `ssh host illogicald --stdio` on a machine you have not used
    /// today should work rather than explain itself.
    spawn: bool = true,
    /// How long a daemon we started gets to bind its socket before we give up.
    startup_timeout_ns: u64 = 10 * std.time.ns_per_s,
    /// How often to retry the connect while waiting for that.
    retry_interval_ns: u64 = 20 * std.time.ns_per_ms,
    /// The daemon to start. Null means "this executable", which is what SSH
    /// wants. A caller that wants to observe the spawn -- or start something
    /// other than itself -- names it here.
    exe: ?[]const u8 = null,
};

pub const Error = error{
    /// Nothing was listening, and either we were told not to start a daemon or
    /// the one we started never came up.
    NoServer,
    SpawnFailed,
    PathTooLong,
};

/// Bridge stdin/stdout to the daemon at `socket_path`. Returns when either end
/// closes.
pub fn serve(socket_path: []const u8, opts: Options) !void {
    // SSH hands us whatever mode its pipes happen to be in, and a non-blocking
    // read here would spin a core instead of sleeping.
    sys.setNonblock(sys.STDIN, false);
    sys.setNonblock(sys.STDOUT, false);

    const fd = try dial(socket_path, opts);
    defer sys.closeFd(fd);
    try bridge(sys.STDIN, sys.STDOUT, fd);
}

/// Connect to the daemon, starting one if there is none and we are allowed to.
pub fn dial(socket_path: []const u8, opts: Options) !sys.fd_t {
    if (sys.connectUnix(socket_path)) |fd| return fd else |_| {}
    if (!opts.spawn) return error.NoServer;

    try spawnDaemon(socket_path, opts.exe);
    return connectWithin(socket_path, opts.startup_timeout_ns, opts.retry_interval_ns) orelse
        error.NoServer;
}

/// Retry `connect` until it succeeds or the deadline passes.
///
/// A daemon we just started has not bound its socket yet, and there is no
/// event to wait on: the socket file appearing is not the same instant as
/// `listen`, so watching the directory would only trade this loop for a
/// racier one.
fn connectWithin(socket_path: []const u8, timeout_ns: u64, interval_ns: u64) ?sys.fd_t {
    const deadline = sys.monotonicNs() + timeout_ns;
    while (true) {
        if (sys.connectUnix(socket_path)) |fd| return fd else |_| {}
        if (sys.monotonicNs() >= deadline) return null;
        sys.sleepNs(interval_ns);
    }
}

/// Start `illogicald` on this machine, detached, listening on `socket_path`.
fn spawnDaemon(socket_path: []const u8, exe_override: ?[]const u8) !void {
    // Everything the child needs must be NUL-terminated before the fork: a
    // forked child may not allocate.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    var exe_z: [std.fs.max_path_bytes]u8 = undefined;
    const exe = if (exe_override) |e|
        e
    else
        sys.selfExePath(&exe_buf) catch return error.SpawnFailed;
    if (exe.len >= exe_z.len) return error.PathTooLong;
    @memcpy(exe_z[0..exe.len], exe);
    exe_z[exe.len] = 0;

    var sock_z: [std.fs.max_path_bytes]u8 = undefined;
    if (socket_path.len >= sock_z.len) return error.PathTooLong;
    @memcpy(sock_z[0..socket_path.len], socket_path);
    sock_z[socket_path.len] = 0;

    // Where the daemon's stderr goes. Beside the socket, which is also where
    // the park store lives, so a daemon nobody started by hand still has one
    // place to complain -- see `spawnDetached`.
    //
    // Created here, before the fork. `Server.init` creates this directory too,
    // but not until the daemon is already running -- so on the *first*
    // auto-start the open below failed with ENOENT and the daemon silently
    // fell back to /dev/null, which is exactly the run where a park-key
    // failure matters most.
    var log_z: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fs.path.dirname(socket_path) orelse ".";
    sys.makeDirPath(dir);
    const log_path = std.fmt.bufPrintZ(&log_z, "{s}/daemon.log", .{dir}) catch
        return error.PathTooLong;

    const exe_ptr: [*:0]const u8 = @ptrCast(&exe_z);
    const sock_ptr: [*:0]const u8 = @ptrCast(&sock_z);
    const argv = [_:null]?[*:0]const u8{ exe_ptr, "--socket", sock_ptr };

    log.info("no daemon at {s}; starting one, logging to {s}", .{ socket_path, log_path });
    try spawnDetached(exe_ptr, &argv, log_path.ptr);
}

/// Start `argv` in a session of its own, with no standard streams, and do not
/// become its parent.
///
/// Double fork. The intermediate child exits immediately, so the daemon is
/// reparented to init and there is nothing left for this process to reap —
/// which matters here more than usual, because this process lives for one SSH
/// session and the daemon must outlive it by hours.
fn spawnDetached(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    log_path: [*:0]const u8,
) !void {
    const pid = sys.forkProcess() catch return error.SpawnFailed;
    if (pid == 0) {
        // Intermediate child. Nothing here may allocate or return.
        _ = sys.newSession();
        const grandchild = sys.forkProcess() catch sys.exitProcess(1);
        if (grandchild != 0) sys.exitProcess(0);

        // The daemon must not inherit our stdout: it prints a banner there,
        // and our stdout is the client's frame stream. Refusing to exec is the
        // only safe answer if we cannot take it away, because injected text
        // would look to the client like a malformed frame.
        detachStdio(log_path) catch sys.exitProcess(1);
        // Everything else our parent had open. A daemon started this way lives
        // for days and hands each inherited descriptor on to every shell it
        // spawns; an `~/.ssh/rc` or `authorized_keys command=` wrapper that
        // opened a credential file before exec'ing us is enough to leak one.
        sys.closeFrom(sys.STDERR + 1);
        sys.exec(file, argv);
        sys.exitProcess(127);
    }
    // The intermediate child exits at once, so this does not wait on the
    // daemon.
    _ = sys.wait(pid);
}

/// Give the daemon no stdin, no stdout, and a *real* stderr.
///
/// Stderr is not `/dev/null`, and that is the whole point of taking a path.
/// The daemon reports a failed park key there and carries on -- `Server.init`
/// treats it as loud but not fatal -- and park files are then written in the
/// clear, defeating F3. Sent to `/dev/null` that condition is unobservable and
/// permanent, and the auto-start path is the one nobody is watching.
fn detachStdio(log_path: [*:0]const u8) !void {
    const null_fd = try sys.openDevNull();
    sys.dup2Fd(null_fd, sys.STDIN);
    sys.dup2Fd(null_fd, sys.STDOUT);
    if (null_fd > sys.STDERR) sys.closeFd(null_fd);

    // A daemon with no diagnostics at all is worse than one whose log we could
    // not open, so fall back rather than refuse to start.
    if (sys.openAppend(log_path)) |log_fd| {
        sys.dup2Fd(log_fd, sys.STDERR);
        if (log_fd > sys.STDERR) sys.closeFd(log_fd);
    } else |_| {
        const fallback = try sys.openDevNull();
        sys.dup2Fd(fallback, sys.STDERR);
        if (fallback > sys.STDERR) sys.closeFd(fallback);
    }
}

/// One direction of the splice.
const Pump = struct {
    from: sys.fd_t,
    to: sys.fd_t,
    /// Broken when this direction ends, so the other one comes back from
    /// whichever syscall it is in.
    ///
    /// Both pumps set this, and to the same descriptor: the socket is the one
    /// end of the splice that *can* be broken from another thread, and each
    /// direction touches it — upstream writes to it, downstream reads from it.
    /// Breaking it is therefore the only wake that works in every case. The
    /// signal below is not a substitute: a pump blocked in `sys.writeAll`
    /// absorbs every signal, because `writeFd` retries on `EINTR` by design.
    shutdown_on_exit: ?sys.fd_t = null,
    /// Shared: set by whichever direction ends first.
    stop: *std.atomic.Value(bool),
    /// This pump has left `run`. Read by the interrupt loop below, which must
    /// not stop signalling until the thread is actually out of `read`.
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Pump) void {
        defer {
            self.stop.store(true, .release);
            if (self.shutdown_on_exit) |fd| sys.shutdownFd(fd);
            self.done.store(true, .release);
        }

        var buf: [buf_size]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            const n = sys.readFdOnce(self.from, &buf) catch |err| switch (err) {
                // A signal, which here means the other direction has ended and
                // wants this one to notice. `readFdOnce` rather than `readFd`
                // for exactly that: a retry loop inside the read would swallow
                // the interruption and go straight back to sleep.
                error.Interrupted => continue,
                else => break,
            };
            if (n == 0) break;
            sys.writeAll(self.to, buf[0..n]) catch break;
        }
    }
};

/// Copy bytes between a client pipe and a daemon socket until either closes.
///
/// `in_fd` and `out_fd` may be the same descriptor; over SSH they are the two
/// halves of a pipe pair, and in the tests they are one socket.
pub fn bridge(in_fd: sys.fd_t, out_fd: sys.fd_t, sock_fd: sys.fd_t) !void {
    // Before the first `interruptThread` below, or delivery kills us.
    sys.installThreadInterrupt();

    var stop: std.atomic.Value(bool) = .init(false);
    // Both directions break the socket on the way out. Whichever ends first,
    // the other is either reading it or writing it, so this is the wake that
    // works for both -- see `Pump.shutdown_on_exit`.
    var upstream: Pump = .{
        .from = in_fd,
        .to = sock_fd,
        .shutdown_on_exit = sock_fd,
        .stop = &stop,
    };
    var downstream: Pump = .{
        .from = sock_fd,
        .to = out_fd,
        .shutdown_on_exit = sock_fd,
        .stop = &stop,
    };

    const t = try std.Thread.spawn(.{ .stack_size = stack_size }, Pump.run, .{&upstream});

    // Downstream on this thread: it is the direction that carries output, and
    // the one that should not pay for a thread hop.
    downstream.run();

    // Downstream has broken the socket, so an upstream pump blocked *writing*
    // to it has already failed and left. One asleep in `read` on stdin has
    // not: a pipe cannot be shut down from the far side, so it is signalled.
    //
    // In a loop, and unbounded, for the same reason as
    // `Terminal.stopReaderLocked`: delivery only interrupts the syscall the
    // thread is in at that instant. It is bounded in practice by the shutdown
    // above -- without it, an upstream pump wedged in `sys.writeAll` absorbs
    // every one of these signals (`writeFd` retries on `EINTR`) and this loop
    // spins at 50 Hz for the life of the process, leaking the process and its
    // SSH channel on every dropped connection.
    var attempts: usize = 0;
    while (!upstream.done.load(.acquire)) : (attempts += 1) {
        sys.interruptThread(t.getHandle());
        sys.sleepNs(if (attempts < interrupt_burst)
            std.time.ns_per_ms
        else
            20 * std.time.ns_per_ms);
    }
    t.join();
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;
const protocol = illogical.protocol;
const Server = @import("Server.zig");

/// A connected pair of unix stream sockets standing in for the pipe SSH gives
/// the bridge: one end is the bridge's stdin *and* stdout, the other is the
/// client.
const Pipe = struct {
    listener: sys.fd_t,
    bridge_end: sys.fd_t,
    client_end: sys.fd_t,
    path_buf: [96]u8 = undefined,
    path_len: usize = 0,

    fn open(tag: []const u8) !Pipe {
        var self: Pipe = .{ .listener = -1, .bridge_end = -1, .client_end = -1 };
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
        self.bridge_end = try sys.acceptFd(self.listener);
        return self;
    }

    fn close(self: *Pipe) void {
        sys.closeFd(self.bridge_end);
        sys.closeFd(self.client_end);
        sys.closeFd(self.listener);
        self.path_buf[self.path_len] = 0;
        sys.unlinkPath(@ptrCast(&self.path_buf));
    }
};

fn sendFrame(fd: sys.fd_t, t: protocol.FrameType, id: u64, payload: []const u8) !void {
    var header_buf: [protocol.header_len]u8 = undefined;
    const header: protocol.Header = .{ .type = t, .session = id, .len = @intCast(payload.len) };
    header.encode(&header_buf);
    try sys.writeAll(fd, &header_buf);
    if (payload.len > 0) try sys.writeAll(fd, payload);
}

/// Read the next frame that is a reply.
///
/// `sessions_changed` is a broadcast, and the server sends it to every client
/// including the one whose `create` caused it, so it turns up unbidden between
/// a request and its answer.
fn recvFrame(fd: sys.fd_t, gpa: std.mem.Allocator, payload: *std.ArrayList(u8)) !protocol.Header {
    while (true) {
        var header_buf: [protocol.header_len]u8 = undefined;
        try sys.readAll(fd, &header_buf);
        const header = try protocol.Header.decode(&header_buf);
        try payload.resize(gpa, header.len);
        if (header.len > 0) try sys.readAll(fd, payload.items);
        if (header.type == .sessions_changed) continue;
        return header;
    }
}

test "the bridge carries a whole conversation in both directions" {
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sock_buf: [96]u8 = undefined;
    const sock_path = try std.fmt.bufPrintZ(
        &sock_buf,
        "/tmp/illogical-stdio-daemon-{d}.sock",
        .{std.c.getpid()},
    );
    defer sys.unlinkPath(sock_path.ptr);

    var state_buf: [96]u8 = undefined;
    const state_root = try std.fmt.bufPrint(
        &state_buf,
        "/tmp/illogical-stdio-state-{d}",
        .{std.c.getpid()},
    );
    defer std.Io.Dir.cwd().deleteTree(io, state_root) catch {};

    const server = try Server.init(gpa, io, sock_path, state_root);
    defer server.deinit();
    try server.listen();
    const accepting = try std.Thread.spawn(.{}, Server.run, .{server});
    defer accepting.join();
    defer server.stop();

    var pipe = try Pipe.open("stdio-pipe");
    defer pipe.close();

    // The bridge dials the daemon exactly as `serve` does, then splices. One
    // descriptor for both directions, which is the case `bridge` has to
    // tolerate.
    const sock = try dial(sock_path, .{ .spawn = false });
    const Runner = struct {
        fn go(in_fd: sys.fd_t, out_fd: sys.fd_t, s: sys.fd_t) void {
            bridge(in_fd, out_fd, s) catch {};
            sys.closeFd(s);
        }
    };
    const bridging = try std.Thread.spawn(
        .{ .stack_size = stack_size },
        Runner.go,
        .{ pipe.bridge_end, pipe.bridge_end, sock },
    );
    defer bridging.join();
    // However this test leaves -- assertion or success -- the bridge has to
    // come back before the join above. Half-closing the client's end is what
    // `ssh` exiting does, and it is the only thing that ends the upstream
    // pump. Registered after the spawn so it runs before the join.
    defer _ = std.c.shutdown(pipe.client_end, 1);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    // Handshake, over the bridge.
    const hello = try protocol.body.encode(gpa, protocol.body.Hello{ .client = "bridge-test" });
    defer gpa.free(hello);
    try sendFrame(pipe.client_end, .hello, protocol.control_session, hello);
    try testing.expectEqual(
        protocol.FrameType.welcome,
        (try recvFrame(pipe.client_end, gpa, &payload)).type,
    );

    // A frame with a body, in both directions, so a bridge that dropped or
    // duplicated a byte would desynchronize the stream rather than merely lose
    // a message.
    const create = try protocol.body.encode(gpa, protocol.body.Create{
        .session_name = "bridged",
        .name = "one",
        .argv = &.{ "/bin/sh", "-c", "printf BRIDGED; sleep 30" },
    });
    defer gpa.free(create);
    try sendFrame(pipe.client_end, .create, protocol.control_session, create);
    const created_header = try recvFrame(pipe.client_end, gpa, &payload);
    try testing.expectEqual(protocol.FrameType.created, created_header.type);
    const created = try protocol.body.decode(protocol.body.Created, gpa, payload.items);
    defer created.deinit();
    // `Terminal.destroy` closes the PTY but does not signal the child, so
    // without this the shell outlives the test.
    defer server.killTerminal(created.value.terminal, 0) catch {};

    try sendFrame(pipe.client_end, .list, protocol.control_session, &.{});
    const list_header = try recvFrame(pipe.client_end, gpa, &payload);
    try testing.expectEqual(protocol.FrameType.session_list, list_header.type);
    const list = try protocol.body.decode(protocol.body.SessionList, gpa, payload.items);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.value.terminals.len);
    try testing.expectEqual(created.value.terminal, list.value.terminals[0].id);
    try testing.expectEqualStrings("bridged", list.value.sessions[0].name);

    // A `ping` of a megabyte -- the largest frame the protocol allows -- comes
    // back byte for byte. This is the assertion the whole file is for: the
    // bridge is a splice, so a frame larger than its copy buffer must survive
    // being cut into pieces and reassembled.
    const big = try gpa.alloc(u8, protocol.max_payload_len);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try sendFrame(pipe.client_end, .ping, 0, big);
    const pong = try recvFrame(pipe.client_end, gpa, &payload);
    try testing.expectEqual(protocol.FrameType.pong, pong.type);
    try testing.expectEqualSlices(u8, big, payload.items);

    // Closing the client's end ends the bridge, which is how `ssh` exiting
    // gets the daemon to drop the connection. Both pumps have to come back:
    // one on end-of-file, the other on the signal the first sends it.
    _ = std.c.shutdown(pipe.client_end, 1);
}

test "a detached daemon outlives its parent, keeps a stderr, and inherits nothing" {
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const pid = std.c.getpid();
    var marker_buf: [96]u8 = undefined;
    const marker = try std.fmt.bufPrintZ(&marker_buf, "/tmp/illogical-detached-{d}", .{pid});
    defer sys.unlinkPath(marker.ptr);
    std.Io.Dir.cwd().deleteFile(io, marker) catch {};

    var log_buf: [96]u8 = undefined;
    const log_path = try std.fmt.bufPrintZ(&log_buf, "/tmp/illogical-detached-{d}.log", .{pid});
    defer sys.unlinkPath(log_path.ptr);
    std.Io.Dir.cwd().deleteFile(io, log_path) catch {};

    var secret_buf: [96]u8 = undefined;
    const secret = try std.fmt.bufPrintZ(&secret_buf, "/tmp/illogical-secret-{d}", .{pid});
    defer sys.unlinkPath(secret.ptr);

    // A descriptor the daemon has no business seeing, standing in for the
    // credential file an `~/.ssh/rc` wrapper might have open. Without
    // `closeFrom` the grandchild inherits it and hands it to every shell it
    // ever spawns -- for days.
    //
    // Whatever number `open` gives us, rather than a hard-coded one: this is a
    // thirty-test binary and dup2'ing onto a fixed slot would silently smash
    // whatever another test had there.
    // Read-write, though nothing reads it: the probe is `true <&N`, and the
    // pdksh family checks the access mode of `<&n` rather than only whether
    // the descriptor exists. Write-only there answers "not open for reading",
    // which reads as CLEAN -- a leaked descriptor reported as closed.
    const secret_fd = try sys.openReadWrite(secret.ptr);
    defer sys.closeFd(secret_fd);

    // ...but placed into 3..9 rather than left where `open` put it, because
    // the check below only discriminates there. Above 9 the `/bin/sh` running
    // the script has its own descriptor in the way: both dash and bash save a
    // redirected fd with `F_DUPFD` from 10 upward for the length of a compound
    // command, and the script's `> marker` and `2>/dev/null` are two of those,
    // so `true <&10` succeeds and the test reads LEAKED however well
    // `closeFrom` worked. At or below 2 the grandchild's own stdio answers, which
    // `detachStdio` has just pointed at /dev/null and the log.
    //
    // A skip was the obvious answer and the wrong one: seven descriptors
    // leaked into this binary by anything upstream would turn the only
    // regression test for `closeFrom` into a silent pass, and `spawnDetached`
    // could then lose its `closeFrom` call with the suite still green.
    // `F_DUPFD` places it deterministically, and failing to is an error.
    const placed = try sys.dupFrom(secret_fd, 3);
    defer sys.closeFd(placed);
    if (placed > 9) return error.NoRoomForSecretDescriptor;

    // Stands in for the daemon: slow enough to still be running when
    // `spawnDetached` returns, so the marker proves the grandchild survived
    // the intermediate child's exit. It also reports what it inherited, and
    // complains on stderr the way a daemon with no park key does.
    var script_buf: [512]u8 = undefined;
    const script = try std.fmt.bufPrintZ(
        &script_buf,
        // `true`, not `:`. `:` is a POSIX *special* built-in, and a
        // redirection error on one of those "shall cause the shell to exit" --
        // so on dash, which is /bin/sh on Debian and Ubuntu, a correctly
        // closed descriptor exits the shell at status 2 before the `else`
        // branch can write CLEAN. The test would then fail on exactly the
        // platforms where the code works. `true` is a regular built-in and
        // merely returns non-zero. Checked on sh, dash, bash, zsh and ksh.
        //
        // The `2>/dev/null` does not suppress the diagnostic, incidentally --
        // redirections apply left to right, so `<&{d}` has already failed and
        // printed by the time it is applied, and the line lands in the daemon
        // log on every green run. It stays because it is one of the two
        // compound-command fd saves the 3..9 placement above is reasoned
        // about; removing it would falsify that paragraph. The log assertion
        // is an `indexOf`, so the extra line costs nothing.
        "sleep 0.2; echo DAEMON_COMPLAINT >&2; " ++
            "if true <&{d} 2>/dev/null; then echo LEAKED; else echo CLEAN; fi > {s}",
        .{ placed, marker },
    );
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", @ptrCast(script.ptr) };

    const before = sys.monotonicNs();
    try spawnDetached("/bin/sh", &argv, log_path.ptr);
    // The wait inside is for the intermediate child, which exits immediately.
    // If it were waiting for the grandchild this would be 200ms, and the
    // daemon would hold up every SSH connection for as long as it ran.
    try testing.expect(sys.monotonicNs() - before < 100 * std.time.ns_per_ms);

    var waited: usize = 0;
    while (waited < 5000) : (waited += 10) {
        if (std.Io.Dir.cwd().access(io, marker, .{})) |_| break else |_| {}
        sys.sleepNs(10 * std.time.ns_per_ms);
    } else return error.DetachedChildNeverRan;

    const inherited = try std.Io.Dir.cwd().readFileAlloc(io, marker, gpa, .limited(64));
    defer gpa.free(inherited);
    try testing.expectEqualStrings("CLEAN", std.mem.trim(u8, inherited, " \n"));

    // And the daemon has somewhere to complain. Sent to /dev/null, a park-key
    // failure -- which leaves every park file in the clear -- is invisible
    // forever, and auto-start is the path nobody is watching.
    const complaint = try std.Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(4096));
    defer gpa.free(complaint);
    try testing.expect(std.mem.indexOf(u8, complaint, "DAEMON_COMPLAINT") != null);
}

test "dialling waits for a daemon that is still coming up" {
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &buf,
        "/tmp/illogical-dial-{d}.sock",
        .{std.c.getpid()},
    );
    defer sys.unlinkPath(path.ptr);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // Nothing listening and not allowed to start anything: the honest answer
    // is that there is no server, not a hang.
    try testing.expectError(error.NoServer, dial(path, .{ .spawn = false }));

    // A daemon that takes a moment to bind, which is the case the retry loop
    // exists for: `spawnDaemon` returns as soon as the fork is away, long
    // before the socket is there to connect to.
    const Late = struct {
        fn listen(p: [:0]const u8) void {
            sys.sleepNs(150 * std.time.ns_per_ms);
            const addr = sys.unixAddr(p) catch return;
            const fd = sys.unixSocket() catch return;
            sys.bindUnix(fd, &addr) catch return;
            sys.listenFd(fd, 1) catch return;
            const accepted = sys.acceptFd(fd) catch {
                sys.closeFd(fd);
                return;
            };
            sys.closeFd(accepted);
            sys.closeFd(fd);
        }
    };
    const late = try std.Thread.spawn(.{}, Late.listen, .{path});
    defer late.join();

    const fd = connectWithin(path, 5 * std.time.ns_per_s, 10 * std.time.ns_per_ms) orelse
        return error.NeverConnected;
    sys.closeFd(fd);
}

test "auto-start makes the daemon's state directory before it forks" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Two levels that do not exist yet, which is the first-auto-start case.
    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(
        &root_buf,
        "/tmp/illogical-spawndir-{d}",
        .{std.c.getpid()},
    );
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var sock_buf: [160]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sock_buf, "{s}/state/server.sock", .{root});

    // `/usr/bin/true` stands in for the daemon: `spawnDaemon` only has to
    // reach its fork, and what it execs is not what is under test.
    //
    // `Server.init` creates this directory too, but not until the daemon is
    // already running -- so on the first auto-start the log open inside it
    // failed with ENOENT and the daemon fell back to /dev/null, which is
    // exactly the run where a park-key failure matters most. Nothing else
    // covers this: `spawnDaemon` is reachable only from `dial` with
    // `.spawn = true`, and every other test here passes false.
    try spawnDaemon(sock, "/usr/bin/true");

    // Made before the fork, so it is there the moment the call returns --
    // no waiting on a grandchild we deliberately do not parent.
    var dir_buf: [160]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/state", .{root});
    try std.Io.Dir.cwd().access(io, dir, .{});
}
