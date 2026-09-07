//! illogicald — the illogical session server.
//!
//! Owns every PTY, every terminal's state, and the park store. Clients come and
//! go; sessions do not.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const illogical = @import("illogical");
const Server = @import("Server.zig");
const stdio = @import("stdio.zig");

const usage =
    \\illogicald — the illogical session server
    \\
    \\Usage: illogicald [options]
    \\
    \\Options:
    \\  --socket <path>          Control socket (default: $XDG_STATE_HOME/illogical/server.sock)
    \\  --stdio                  Speak the protocol on stdin/stdout instead of
    \\                           listening: bridge to this host's daemon, starting
    \\                           one if there is none. What `ssh <host> illogicald
    \\                           --stdio` runs.
    \\  --ensure                 Make sure a daemon is listening, then exit. Starts
    \\                           one, detached, if there is none, and leaves the
    \\                           existing one alone if there is. What the Mac app
    \\                           runs when its own connect is refused.
    \\  --no-spawn               With --stdio or --ensure, fail rather than start
    \\                           a daemon
    \\  --park-after <s>         PTY-read idle time before a terminal parks to disk (default: 60)
    \\  --pty-park-after <s>     Unobserved time before a PTY leaves its dedicated
    \\                           thread for the shared poller (default: 5)
    \\  --client-park-after <s>  Quiet time before a client's pipeline buffers are
    \\                           freed (default: 10)
    \\  --version                Print version and exit
    \\  --help                   Print this help and exit
    \\
;

var global_server: ?*Server = null;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    // `initStreaming`, not `init`. The default writes positionally, at the
    // writer's own offset starting from zero, ignoring the file offset the
    // shell and every other writer share. Here that is the startup banner, so
    // `illogicald >> log` would overwrite the head of the log rather than
    // append to it. The CLI has the same line for a louder reason; see there.
    var stdout_file_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var socket_path: ?[]const u8 = null;
    var park_after_s: ?u64 = null;
    var pty_park_after_s: ?u64 = null;
    var client_park_after_s: ?u64 = null;
    var stdio_mode = false;
    var ensure_mode = false;
    var spawn_daemon = true;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.writeAll(usage);
            return out.flush();
        }
        if (std.mem.eql(u8, arg, "--stdio")) {
            stdio_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ensure")) {
            ensure_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-spawn")) {
            spawn_daemon = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            try out.print("illogicald {s}\n", .{illogical.version});
            return out.flush();
        }
        if (std.mem.eql(u8, arg, "--park-after")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("error: --park-after needs a number of seconds\n");
                try out.flush();
                return error.InvalidArgs;
            }
            park_after_s = std.fmt.parseInt(u64, args[i], 10) catch {
                try out.print("error: bad --park-after value '{s}'\n", .{args[i]});
                try out.flush();
                return error.InvalidArgs;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--pty-park-after")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("error: --pty-park-after needs a number of seconds\n");
                try out.flush();
                return error.InvalidArgs;
            }
            pty_park_after_s = std.fmt.parseInt(u64, args[i], 10) catch {
                try out.print("error: bad --pty-park-after value '{s}'\n", .{args[i]});
                try out.flush();
                return error.InvalidArgs;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--client-park-after")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("error: --client-park-after needs a number of seconds\n");
                try out.flush();
                return error.InvalidArgs;
            }
            client_park_after_s = std.fmt.parseInt(u64, args[i], 10) catch {
                try out.print("error: bad --client-park-after value '{s}'\n", .{args[i]});
                try out.flush();
                return error.InvalidArgs;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--socket")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("error: --socket needs a path\n");
                try out.flush();
                return error.InvalidArgs;
            }
            socket_path = args[i];
            continue;
        }
        try out.print("error: unknown option '{s}'\n", .{arg});
        try out.flush();
        return error.InvalidArgs;
    }

    const path = if (socket_path) |p|
        try arena.dupe(u8, p)
    else
        try Server.defaultSocketPath(arena);

    // A client disconnecting mid-write must not take the daemon down, and the
    // stdio bridge writing to a stdout SSH has already closed must not take
    // *it* down either. Before both branches, so neither is a special case.
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ignore, null);

    // Before `--stdio`, because `--ensure` is the cheaper request and the two
    // together would otherwise silently mean "bridge": a caller that asked for
    // both wants a daemon and no pipe.
    if (ensure_mode) {
        const started = stdio.ensure(path, .{ .spawn = spawn_daemon }) catch |err| {
            // Stderr, and never stdout: the app reads this to explain itself to
            // a human, and one place to look is the whole value of naming the
            // log here. `spawnDetached` points the daemon's own stderr at that
            // file, so a daemon that started and then died says why there and
            // nowhere else.
            reportEnsureFailure(err, path, spawn_daemon);
        };
        // One line, and it is the only thing on stdout: the app does not parse
        // it, but a person running this by hand wants to know which of the two
        // happened, because "already running" means their terminals are still
        // where they left them.
        switch (started) {
            .already_running => try out.print("illogicald is already running on {s}\n", .{path}),
            .started => try out.print("illogicald started, listening on {s}\n", .{path}),
        }
        return out.flush();
    }

    if (stdio_mode) {
        // Nothing on stdout but frames from here on: it is the client's
        // transport. Diagnostics go to stderr, which SSH keeps separate.
        stdio.serve(path, .{ .spawn = spawn_daemon }) catch |err| {
            std.log.err(
                "illogicald --stdio: no daemon at {s} ({t}); " ++
                    "check that illogicald can start on this host",
                .{ path, err },
            );
            // Exit rather than return, for the same reason `--ensure` does: a
            // Debug build returning an error from `main` prints a three-frame
            // return trace with absolute source paths, and this stderr is
            // ssh's, which the client reads back as the reason the remote is
            // unreachable.
            std.process.exit(1);
        };
        return;
    }

    // The park store lives beside the socket.
    const state_root = std.fs.path.dirname(path) orelse ".";

    const server = try Server.init(gpa, init.io, path, state_root);
    defer server.deinit();
    if (park_after_s) |seconds| {
        server.park_config.park_after_ns = seconds * std.time.ns_per_s;
    }
    if (pty_park_after_s) |seconds| {
        server.park_config.pty_park_unobserved_after_ns = seconds * std.time.ns_per_s;
    }
    if (client_park_after_s) |seconds| {
        server.park_config.client_park_after_ns = seconds * std.time.ns_per_s;
    }
    global_server = server;

    const shutdown: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &shutdown, null);
    posix.sigaction(posix.SIG.TERM, &shutdown, null);

    server.listen() catch |err| switch (err) {
        // Not a failure worth a stack trace: somebody -- or an SSH bridge --
        // has already started one, and it owns the terminals.
        error.AlreadyRunning => {
            try out.print("illogicald is already running on {s}\n", .{path});
            try out.flush();
            return;
        },
        else => return err,
    };
    try out.print(
        "illogicald {s} listening on {s} (park after {d}s, {d} poller threads)\n",
        .{
            illogical.version,
            path,
            server.park_config.park_after_ns / std.time.ns_per_s,
            server.pty_poller.threadCount(),
        },
    );
    try out.flush();

    try server.run();
}

/// Say why `--ensure` failed, in one sentence, and exit 1.
///
/// One line on stderr, written straight to the descriptor, and then `_exit`.
/// Every part of that is deliberate, because this text goes in front of a
/// person twice: it is what someone running `illogicald --ensure` by hand
/// reads, and it is what the Mac app quotes verbatim into "No server" when the
/// start it asked for did not happen.
///
/// - Not `std.log.err`, which prefixes `error: ` and would make the app's
///   sentence read "…could not start a server: error: …".
/// - Not `return error.NoServer` from `main`, which in a Debug build -- the
///   build `just stage-daemon` embeds -- prints `error: NoServer` and a
///   three-frame return trace with absolute `.zig` paths after it. The app
///   showed that trace to people (REVIEW F4).
/// - Self-contained sentences, naming the path and the log rather than an
///   error name: `NoServer` means nothing to the person reading it, and the
///   app has no way to translate it.
fn reportEnsureFailure(err: anyerror, path: []const u8, spawn_daemon: bool) noreturn {
    const dir = std.fs.path.dirname(path) orelse ".";
    const startup_s = (stdio.Options{}).startup_timeout_ns / std.time.ns_per_s;

    var buf: [2 * std.fs.max_path_bytes + 256]u8 = undefined;
    const line = switch (err) {
        error.NoServer => if (!spawn_daemon)
            std.fmt.bufPrint(
                &buf,
                "illogicald --ensure: nothing is listening on {s}, and --no-spawn was given\n",
                .{path},
            )
        else
            std.fmt.bufPrint(
                &buf,
                "illogicald --ensure: started a daemon for {s}, but nothing answered " ++
                    "within {d} s; its log is {s}/daemon.log\n",
                .{ path, startup_s, dir },
            ),
        error.StateDirUnwritable => std.fmt.bufPrint(
            &buf,
            "illogicald --ensure: cannot write to {s}, where the socket and daemon.log live\n",
            .{dir},
        ),
        error.SocketPathNotAbsolute => std.fmt.bufPrint(
            &buf,
            "illogicald --ensure: the socket path must be absolute (got {s}); " ++
                "the daemon outlives this shell and its working directory\n",
            .{path},
        ),
        error.SpawnFailed => std.fmt.bufPrint(
            &buf,
            "illogicald --ensure: could not fork a daemon for {s}\n",
            .{path},
        ),
        error.PathTooLong => std.fmt.bufPrint(
            &buf,
            "illogicald --ensure: the socket path is too long\n",
            .{},
        ),
        else => std.fmt.bufPrint(
            &buf,
            "illogicald --ensure: no daemon on {s} ({t})\n",
            .{ path, err },
        ),
    } catch "illogicald --ensure: no daemon, and the reason did not fit in a line\n";

    illogical.sys.writeAll(illogical.sys.STDERR, line) catch {};
    std.process.exit(1);
}

fn onSignal(_: std.c.SIG) callconv(.c) void {
    if (global_server) |s| s.stop();
}

test {
    _ = illogical;
    _ = Server;
    _ = stdio;
    _ = @import("Terminal.zig");
    _ = @import("Client.zig");
}
