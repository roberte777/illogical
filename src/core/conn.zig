//! A protocol connection.
//!
//! Shared by the CLI and by anything else that speaks to illogicald. Frames are
//! read and written synchronously; callers that want concurrency give the read
//! and write halves to different threads and serialize writes themselves.
//!
//! Two transports, and the frames above them do not know which one they are on:
//!
//! | | |
//! | --- | --- |
//! | local | a unix socket, one descriptor for both directions |
//! | remote | `ssh <dest> illogicald --stdio`, a pipe each way |
//!
//! That is the whole of the remote story on this side. There is no TLS, no
//! listening TCP socket and no credential handling of our own: SSH decides who
//! may connect, and the far end is `src/daemon/stdio.zig` splicing the pipe onto
//! the host's own unix socket. See docs/PROTOCOL.md, "Transport".

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
    /// Reads come from here, writes go there. The same descriptor for a socket;
    /// two ends of two pipes for a command.
    read_fd: sys.fd_t,
    write_fd: sys.fd_t,
    /// The process carrying this connection, when it is a command. Signalled
    /// and reaped by `deinit`.
    child: ?sys.pid_t = null,
    gpa: Allocator,
    read_buf: std.ArrayList(u8) = .empty,
    write_mutex: thread.Mutex = .{},

    pub fn connect(gpa: Allocator, path: []const u8) !Conn {
        const fd = try sys.connectUnix(path);
        return .{ .read_fd = fd, .write_fd = fd, .gpa = gpa };
    }

    /// Run `argv` and speak the protocol over its stdin and stdout.
    ///
    /// The child keeps our stderr, so `ssh` can report a bad host key or a
    /// missing binary where a person will see it.
    pub fn spawn(gpa: Allocator, argv: [:null]const ?[*:0]const u8) !Conn {
        const child = try sys.spawnPiped(argv[0].?, argv.ptr);
        return .{
            .read_fd = child.stdout,
            .write_fd = child.stdin,
            .child = child.pid,
            .gpa = gpa,
        };
    }

    /// How long a command connection's child gets to forward what it still
    /// holds and exit on its own before it is signalled.
    ///
    /// This is not politeness. A frame sent without waiting for a reply --
    /// `kill`, `input`, `detach` -- is still sitting in `ssh`'s stdin pipe when
    /// `deinit` runs, and `ssh` has to encrypt and write it before it is gone.
    /// Signalling immediately discards it: `illogical --host box kill 3` exited
    /// 0 having done nothing at all, every time.
    const child_exit_grace_ns = 2 * std.time.ns_per_s;
    const child_exit_poll_ns = 2 * std.time.ns_per_ms;

    pub fn deinit(self: *Conn) void {
        // The write end first, and on its own: the far end reads end-of-file
        // from it and unwinds, which is how `ssh` learns to exit. The read end
        // stays open until it has, or we would break the channel it is
        // flushing through.
        if (self.write_fd != self.read_fd) sys.closeFd(self.write_fd);

        if (self.child) |pid| {
            // Keep reading while we wait, and throw it away.
            //
            // Not optional. The child is often mid-write to us -- `attach`
            // breaks its read loop on `exited` with up to the daemon's 1 MiB
            // client queue still in flight, and a failed `peek` leaves a whole
            // `screen` frame behind. A child blocked writing into a pipe
            // nobody is draining never gets back to reading its stdin, so it
            // never sees the end-of-file above, and every such exit burned the
            // full grace and then got signalled anyway: `illogical --host box
            // list` took 2.34 s instead of returning at once.
            // Checked, because a drain that is not actually non-blocking is a
            // blocking read on a child that may never write again -- an
            // unbounded wait, which is the one thing the deadline below exists
            // to rule out. If the mode will not take, wait the child out
            // without draining and accept the slow exit.
            const nonblocking = sys.trySetNonblock(self.read_fd, true);
            defer if (nonblocking) sys.setNonblock(self.read_fd, false);

            const deadline = sys.monotonicNs() + child_exit_grace_ns;
            const reaped = while (sys.monotonicNs() < deadline) {
                if (nonblocking) self.drainRead(deadline);
                switch (sys.tryWait(pid)) {
                    .running => sys.sleepNs(child_exit_poll_ns),
                    .exited, .gone => break true,
                }
            } else false;

            // Only now, and only if end-of-file was not enough. `ssh` holding a
            // control master can outlive its own session, and a CLI that waited
            // for that would appear to hang after printing its answer.
            if (!reaped) {
                sys.signal(pid, sys.SIGTERM);
                _ = sys.wait(pid);
            }
            self.child = null;
        }

        sys.closeFd(self.read_fd);
        self.read_buf.deinit(self.gpa);
    }

    /// Read and discard whatever is waiting, without blocking.
    ///
    /// `read_fd` must be non-blocking, and the deadline is checked here rather
    /// than only by the caller: a child that produces bytes as fast as this
    /// discards them -- a remote rc file looping on stdout, or a stand-in
    /// transport under ILLOGICAL_SSH -- never returns 0, so without this the
    /// loop outlasts the grace it is supposed to fit inside and `deinit` never
    /// reaches the SIGTERM that is its whole fallback. `illogical --host box
    /// list` would hang instead of taking at most the grace.
    fn drainRead(self: *Conn, deadline: u64) void {
        var scratch: [4096]u8 = undefined;
        while (sys.monotonicNs() < deadline) {
            const n = sys.readFdOnce(self.read_fd, &scratch) catch return;
            // End of stream, or nothing more for now.
            if (n == 0) return;
        }
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
        try sys.writeAll(self.write_fd, &header_buf);
        if (payload.len > 0) try sys.writeAll(self.write_fd, payload);
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
        try sys.readAll(self.read_fd, &header_buf);
        const header = try protocol.Header.decode(&header_buf);

        self.read_buf.clearRetainingCapacity();
        try self.read_buf.resize(self.gpa, header.len);
        if (header.len > 0) try sys.readAll(self.read_fd, self.read_buf.items);
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

// -- the ssh transport -----------------------------------------------------

/// How to reach a remote daemon.
///
/// Everything about *authentication* is deliberately absent: `ssh` is run as
/// the user runs it, so `~/.ssh/config`, keys, jump hosts and agent forwarding
/// all apply and there is nothing of ours to configure or store.
pub const Ssh = struct {
    /// Anything `ssh` accepts: `host`, `user@host`, or a `Host` alias from the
    /// user's config.
    destination: []const u8,
    /// The daemon to run on the far side. Resolved by the login shell's PATH.
    remote_binary: []const u8 = "illogicald",
    /// The socket the far side's bridge dials, *on that machine*. Null leaves
    /// it to the remote's own default rather than imposing this machine's,
    /// which is why it is not filled in from our `--socket` unless the user
    /// actually passed one.
    socket: ?[]const u8 = null,
    /// The `ssh` to run. A field rather than a constant so a test can stand in
    /// for it, and so someone with a second OpenSSH can say which.
    ssh: []const u8 = "ssh",
    /// Where to keep the multiplexing socket. Null asks for `~/.ssh`; see
    /// `controlPath`.
    control_dir: ?[]const u8 = null,
    /// Turn connection multiplexing off. One SSH connection per terminal is
    /// what this avoids, and a window with four splits opens five.
    multiplex: bool = true,

    /// Seconds between keepalives, and how many may go unanswered. Together
    /// they are how long a dead network takes to become a closed connection,
    /// which is what the client turns into a reconnect — 45 seconds here.
    const alive_interval = "15";
    const alive_count = "3";
    /// How long the multiplexing master lingers after the last connection, so
    /// closing a window and opening another does not re-authenticate.
    const persist = "60";

    /// A unix socket path has about 104 bytes, and OpenSSH renders `%C` as a
    /// 40-character hash. Refuse to ask for multiplexing rather than have ssh
    /// warn about a path it cannot bind on every single connection.
    const control_budget = 100;

    pub fn argv(self: Ssh, arena: Allocator) ![:null]?[*:0]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.appendSlice(arena, &.{
            self.ssh,
            // No pty. A pty would put a line discipline in the middle of a
            // binary frame stream and translate every 0x0a it carried.
            "-T",
            "-o",
            "ServerAliveInterval=" ++ alive_interval,
            "-o",
            "ServerAliveCountMax=" ++ alive_count,
        });

        // One connection per terminal is the client's model, so a window with
        // four splits is five SSH connections. Multiplexing makes the four
        // after the first cost a channel rather than a handshake.
        if (self.multiplex) {
            if (try self.controlPath(arena)) |path| {
                const control = try std.fmt.allocPrint(arena, "ControlPath={s}", .{path});
                try parts.appendSlice(arena, &.{ "-o", "ControlMaster=auto" });
                try parts.appendSlice(arena, &.{ "-o", control });
                try parts.appendSlice(arena, &.{ "-o", "ControlPersist=" ++ persist });
            }
        }

        // `--` first. Without it a destination beginning with `-` is parsed by
        // `ssh` as an option: `-weirdhost` becomes `-w eirdhost` and fails with
        // "Bad tun device". Nothing reachable today gets further than a usage
        // dump, but a destination is user input sitting in an option slot, and
        // `-oProxyCommand=` is what that slot is one argument away from.
        try parts.append(arena, "--");
        try parts.append(arena, self.destination);
        // `ssh` joins what follows with spaces and hands it to the login shell,
        // which is what resolves `illogicald` on the far side.
        try parts.append(arena, self.remote_binary);
        try parts.append(arena, "--stdio");
        // The socket the *far side's* bridge dials. Left null the remote uses
        // its own default, which is the right answer for a machine whose state
        // directory is not laid out like ours.
        if (self.socket) |path| {
            try parts.append(arena, "--socket");
            try parts.append(arena, path);
        }

        const out = try arena.allocSentinel(?[*:0]const u8, parts.items.len, null);
        for (parts.items, 0..) |part, i| out[i] = (try arena.dupeZ(u8, part)).ptr;
        return out;
    }

    /// The `ControlPath` template, or null when there is nowhere short enough
    /// to put it.
    fn controlPath(self: Ssh, arena: Allocator) !?[]const u8 {
        const dir = self.control_dir orelse blk: {
            const home = sys.getenv("HOME") orelse return null;
            break :blk try std.fmt.allocPrint(arena, "{s}/.ssh", .{home});
        };
        const path = try std.fmt.allocPrint(arena, "{s}/illogical-%C", .{dir});
        // `%C` is forty characters at render time and two here.
        if (path.len - 2 + 40 > control_budget) return null;
        return path;
    }
};

// -- tests -----------------------------------------------------------------

fn argvStrings(arena: Allocator, opts: Ssh) ![]const []const u8 {
    const raw = try opts.argv(arena);
    var out: std.ArrayList([]const u8) = .empty;
    for (raw) |item| try out.append(arena, std.mem.span(item.?));
    return out.items;
}

fn indexOfArg(args: []const []const u8, want: []const u8) ?usize {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, want)) return i;
    }
    return null;
}

test "the ssh command ends in the remote daemon, in stdio mode" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try argvStrings(arena, .{
        .destination = "build-box",
        .control_dir = "/tmp",
    });

    try testing.expectEqualStrings("ssh", args[0]);
    // The destination and the command, in that order and last: everything
    // before them is an option, and `ssh` treats the first non-option as the
    // host and the rest as the command.
    try testing.expectEqualStrings("build-box", args[args.len - 3]);
    try testing.expectEqualStrings("illogicald", args[args.len - 2]);
    try testing.expectEqualStrings("--stdio", args[args.len - 1]);
    // ...and `--` immediately before the destination, so a host name is never
    // read as an option.
    try testing.expectEqualStrings("--", args[args.len - 4]);

    // No pty. This is not a preference: a line discipline in the middle of the
    // frame stream would rewrite every 0x0a byte a snapshot chunk carried.
    try testing.expect(indexOfArg(args, "-T") != null);

    // A dead network has to become a closed connection, or the client never
    // learns to reconnect.
    try testing.expect(indexOfArg(args, "ServerAliveInterval=15") != null);
    try testing.expect(indexOfArg(args, "ServerAliveCountMax=3") != null);

    // Multiplexing, so the second terminal on a host costs a channel.
    try testing.expect(indexOfArg(args, "ControlMaster=auto") != null);
    try testing.expect(indexOfArg(args, "ControlPath=/tmp/illogical-%C") != null);
    try testing.expect(indexOfArg(args, "ControlPersist=60") != null);

    // Every `-o` introduces exactly one option, so the count has to match.
    var options: usize = 0;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-o")) options += 1;
    }
    try testing.expectEqual(@as(usize, 5), options);
}

test "a destination that looks like an option is not read as one" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Without the `--`, ssh reads this as `-w eirdhost` and dies with "Bad tun
    // device". A destination is user input in an option slot, and the slot next
    // to it is `-oProxyCommand=`.
    const args = try argvStrings(arena, .{ .destination = "-weirdhost", .multiplex = false });
    const dash_dash = indexOfArg(args, "--") orelse return error.NoTerminator;
    try testing.expectEqualStrings("-weirdhost", args[dash_dash + 1]);
}

test "the remote socket is forwarded, and only when one was asked for" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `--socket` names a path on the *far* machine, which is what the far
    // side's `--stdio` dials. Dropping it silently pointed the user at a
    // different daemon than the one they named.
    const with = try argvStrings(arena, .{
        .destination = "box",
        .socket = "/run/illogical/dev.sock",
        .multiplex = false,
    });
    try testing.expectEqualStrings("--socket", with[with.len - 2]);
    try testing.expectEqualStrings("/run/illogical/dev.sock", with[with.len - 1]);
    try testing.expectEqualStrings("--stdio", with[with.len - 3]);

    // Unset, the remote uses its own default rather than being handed ours --
    // a machine whose state directory is not laid out like this one's.
    const without = try argvStrings(arena, .{ .destination = "box", .multiplex = false });
    try testing.expect(indexOfArg(without, "--socket") == null);
    try testing.expectEqualStrings("--stdio", without[without.len - 1]);
}

test "a remote binary somewhere else is respected" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try argvStrings(arena, .{
        .destination = "me@host",
        .remote_binary = "/opt/illogical/bin/illogicald",
        .ssh = "/usr/bin/ssh",
        .multiplex = false,
    });
    try testing.expectEqualStrings("/usr/bin/ssh", args[0]);
    try testing.expectEqualStrings("me@host", args[args.len - 3]);
    try testing.expectEqualStrings("/opt/illogical/bin/illogicald", args[args.len - 2]);
    try testing.expect(indexOfArg(args, "ControlMaster=auto") == null);
}

test "a control path that would not fit in a unix socket is not asked for" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The shape macOS `TMPDIR` has: deep enough that the rendered hash pushes
    // it past what `bind` accepts. ssh would warn about this on every
    // connection and fall back anyway, so ask for the fallback directly.
    const args = try argvStrings(arena, .{
        .destination = "host",
        .control_dir = "/var/folders/2b/" ++ "x" ** 48 ++ "/T",
    });
    try testing.expect(indexOfArg(args, "ControlMaster=auto") == null);
    // ...and the rest of the command is unaffected.
    try testing.expectEqualStrings("--stdio", args[args.len - 1]);
}

test "a frame sent without waiting for a reply survives deinit" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buf: [96]u8 = undefined;
    const out_path = try std.fmt.bufPrintZ(
        &path_buf,
        "/tmp/illogical-flush-{d}",
        .{std.c.getpid()},
    );
    defer sys.unlinkPath(out_path.ptr);
    std.Io.Dir.cwd().deleteFile(io, out_path) catch {};

    // Stands in for ssh: something that has to be *scheduled* before the bytes
    // in its stdin pipe reach their destination. `deinit` used to close the
    // pipe and SIGTERM in the same breath, which killed it first.
    var script_buf: [256]u8 = undefined;
    const script = try std.fmt.bufPrintZ(&script_buf, "cat > {s}", .{out_path});
    const argv = try arena.allocSentinel(?[*:0]const u8, 3, null);
    argv[0] = "/bin/sh";
    argv[1] = "-c";
    argv[2] = @ptrCast(script.ptr);

    var conn = try Conn.spawn(gpa, argv);
    // `kill` is the shape that broke: one frame, no reply expected, and the
    // process exits immediately after. `illogical --host box kill 3` reported
    // success having sent nothing at all.
    try conn.sendJson(.kill, 3, protocol.body.Kill{});
    conn.deinit();

    const written = try std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .limited(4096));
    defer gpa.free(written);

    var header_buf: [protocol.header_len]u8 = undefined;
    try testing.expect(written.len >= protocol.header_len);
    @memcpy(&header_buf, written[0..protocol.header_len]);
    const header = try protocol.Header.decode(&header_buf);
    try testing.expectEqual(protocol.FrameType.kill, header.type);
    try testing.expectEqual(@as(u64, 3), header.session);
    try testing.expectEqual(written.len - protocol.header_len, header.len);
}

test "deinit drains a child that is blocked writing at us" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A megabyte at us, then exit. A pipe holds 64 KiB, so this child is
    // blocked in `write` long before it is done -- and a child blocked writing
    // never gets back to reading its stdin, so it never sees the end-of-file
    // `deinit` sends it and never exits on its own.
    //
    // Not a contrived shape. `attach` breaks its read loop on `exited` with up
    // to the daemon's 1 MiB client queue still in flight, and a failed `peek`
    // leaves a whole `screen` frame behind. Nothing else in this file reaches
    // it: the other two spawn tests read everything their child sends, or use
    // a child that writes nothing at all.
    const argv = try arena.allocSentinel(?[*:0]const u8, 3, null);
    argv[0] = "/bin/sh";
    argv[1] = "-c";
    argv[2] = "head -c 1000000 /dev/zero";

    var conn = try Conn.spawn(gpa, argv);
    const before = sys.monotonicNs();
    conn.deinit();
    const elapsed = sys.monotonicNs() - before;

    // Undrained, this child cannot reach its own exit, so `deinit` burns the
    // whole two-second grace and then signals it -- `illogical --host box
    // list` took 2.34s to print an answer it already had in hand.
    try testing.expect(elapsed < 500 * std.time.ns_per_ms);
}

test "deinit gives up on a child that never stops writing" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Unbounded, unlike the drain test above: `yes` never reaches end of
    // stream and, because we are draining it, never blocks either. So
    // `readFdOnce` returns neither 0 nor `WouldBlock` and the only thing that
    // can end `drainRead` is its deadline. Without one the loop is `while
    // (true)` and `deinit` never returns at all -- `illogical --host box list`
    // hangs having already printed its answer. The shape is real: a remote
    // login shell whose rc file writes in a loop reaches our `read_fd`,
    // because `-T` makes the remote command's stdout the channel itself.
    const argv = try arena.allocSentinel(?[*:0]const u8, 3, null);
    argv[0] = "/bin/sh";
    argv[1] = "-c";
    argv[2] = "yes";

    var conn = try Conn.spawn(gpa, argv);
    const before = sys.monotonicNs();
    conn.deinit();
    const elapsed = sys.monotonicNs() - before;

    // It must cost the grace and then signal -- not less, which would mean the
    // drain gave up early on a child that was merely busy, and not more, which
    // is the hang.
    try testing.expect(elapsed >= Conn.child_exit_grace_ns);
    try testing.expect(elapsed < 2 * Conn.child_exit_grace_ns);
}

test "a command connection speaks frames over its child's pipes" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `cat` is the smallest thing that behaves like the far end of an SSH
    // pipe: whatever we write comes back, framed exactly as it was sent. What
    // is under test is the transport, not the server.
    const argv = try arena.allocSentinel(?[*:0]const u8, 1, null);
    argv[0] = "/bin/cat";

    var conn = try Conn.spawn(gpa, argv);
    defer conn.deinit();

    // Large enough to cross a pipe buffer, so a transport that lost track of a
    // partial write would truncate it.
    const payload = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 17);

    const Writer = struct {
        fn go(c: *Conn, bytes: []const u8) void {
            c.send(.input, 42, bytes) catch {};
        }
    };
    // On a thread: 128 KiB is more than a pipe holds, so the write blocks
    // until this thread has read some of it back.
    const writing = try std.Thread.spawn(.{}, Writer.go, .{ &conn, payload });
    defer writing.join();

    const frame = try conn.recv();
    try testing.expectEqual(protocol.FrameType.input, frame.header.type);
    try testing.expectEqual(@as(u64, 42), frame.header.session);
    try testing.expectEqualSlices(u8, payload, frame.payload);
}
