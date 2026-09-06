//! illogicald — the illogical session server.
//!
//! Owns every PTY, every terminal's state, and the park store. Clients come and
//! go; sessions do not.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const illogical = @import("illogical");
const Server = @import("Server.zig");

const usage =
    \\illogicald — the illogical session server
    \\
    \\Usage: illogicald [options]
    \\
    \\Options:
    \\  --socket <path>          Control socket (default: $XDG_STATE_HOME/illogical/server.sock)
    \\  --park-after <s>         PTY-read idle time before a terminal parks to disk (default: 60)
    \\  --pty-park-after <s>     Unobserved time before a PTY leaves its dedicated
    \\                           thread for the shared poller (default: 5)
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
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var socket_path: ?[]const u8 = null;
    var park_after_s: ?u64 = null;
    var pty_park_after_s: ?u64 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.writeAll(usage);
            return out.flush();
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
    global_server = server;

    // A client disconnecting mid-write must not take the daemon down.
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ignore, null);

    const shutdown: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &shutdown, null);
    posix.sigaction(posix.SIG.TERM, &shutdown, null);

    try server.listen();
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

fn onSignal(_: std.c.SIG) callconv(.c) void {
    if (global_server) |s| s.stop();
}

test {
    _ = illogical;
    _ = Server;
    _ = @import("Terminal.zig");
    _ = @import("Client.zig");
}
