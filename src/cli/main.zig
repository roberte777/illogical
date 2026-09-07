//! illogical — control CLI for illogicald.
//!
//! Speaks the same protocol as the GUI clients. `illogical attach` is the
//! compatibility path: it renders into whatever terminal it happens to be
//! running inside, which means repainting the screen as VT rather than handing
//! a snapshot to a real terminal engine. The Mac app takes the fast path.

const std = @import("std");
const Io = std.Io;
const illogical = @import("illogical");
const protocol = illogical.protocol;
const sys = illogical.sys;
const Conn = illogical.conn.Conn;

const usage =
    \\illogical — control a running illogicald
    \\
    \\Usage: illogical <command> [args]
    \\
    \\Commands:
    \\  list                     List sessions and terminals
    \\  new [-s session] [-n name] [--] [cmd...]
    \\                           Create a terminal (default: $SHELL)
    \\  attach <terminal-id>     Attach this terminal to a session terminal
    \\  kill <terminal-id>       Terminate a terminal
    \\  peek <terminal-id>       Print the terminal's screen as plain text
    \\  rename <session-id> <name>
    \\                           Rename a session
    \\  rm-session [--if-empty] <session-id>
    \\                           Delete a session and close its terminals.
    \\                           --if-empty refuses instead of cascading.
    \\
    \\Options:
    \\  --socket <path>          Control socket to connect to
    \\  --host <ssh-dest>        Talk to the daemon on another machine, through
    \\                           `ssh <dest> illogicald --stdio`. Anything ssh
    \\                           accepts works, including a Host alias.
    \\  --remote-bin <path>      The daemon to run there (default: illogicald)
    \\  --version                Print version and exit
    \\  --help                   Print this help and exit
    \\
    \\Environment:
    \\  ILLOGICAL_SOCK           Default control socket
    \\  ILLOGICAL_SSH            The ssh to run for --host (default: ssh)
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [8192]u8 = undefined;
    // `initStreaming`, not `init`. The default is positional writes at the
    // writer's *own* offset, which starts at zero: redirect this to a file and
    // the first line lands on top of whatever was already there, ignoring the
    // file offset the shell and every other writer share. `illogical list >
    // out` came out interleaved with itself.
    var stdout_file_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.writeAll(usage);
        return;
    }

    // Global options may appear anywhere.
    var socket_path: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var remote_bin: []const u8 = "illogicald";
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--socket") and i + 1 < args.len) {
            i += 1;
            socket_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            i += 1;
            host = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--remote-bin") and i + 1 < args.len) {
            i += 1;
            remote_bin = args[i];
            continue;
        }
        try rest.append(arena, arg);
    }

    if (rest.items.len == 0) {
        try out.writeAll(usage);
        return;
    }

    const cmd = rest.items[0];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try out.writeAll(usage);
        return;
    }
    if (std.mem.eql(u8, cmd, "--version")) {
        try out.print("illogical {s}\n", .{illogical.version});
        return;
    }

    // A remote daemon is the same protocol over a different pipe. Everything
    // below this line is identical for both, which is the point of the design:
    // there is no "remote mode", only a different transport.
    var conn = if (host) |dest| conn: {
        // `--socket` still means something remotely: it is the path the far
        // side's bridge dials, on that machine. Left unset it uses that
        // machine's default rather than imposing this one's.
        const remote_argv = try (illogical.conn.Ssh{
            .destination = dest,
            .remote_binary = remote_bin,
            .socket = socket_path,
            // For a second OpenSSH, and for the tests that stand something
            // else in its place.
            .ssh = sys.getenv("ILLOGICAL_SSH") orelse "ssh",
        }).argv(arena);
        break :conn illogical.conn.Conn.spawn(gpa, remote_argv) catch |err| {
            try out.print("illogical: cannot run ssh for {s} ({t})\n", .{ dest, err });
            try out.flush();
            return error.NoServer;
        };
    } else conn: {
        const path = socket_path orelse try defaultSocketPath(arena);
        break :conn Conn.connect(gpa, path) catch |err| {
            try out.print(
                "illogical: cannot reach a server at {s} ({t})\n" ++
                    "           start one with: illogicald\n",
                .{ path, err },
            );
            try out.flush();
            return error.NoServer;
        };
    };
    defer conn.deinit();

    _ = conn.hello(arena, "illogical-cli") catch |err| {
        if (host) |dest| {
            try out.print(
                "illogical: no illogicald on {s} ({t})\n" ++
                    "           it must be on the PATH of a login shell there,\n" ++
                    "           or named with --remote-bin\n",
                .{ dest, err },
            );
            try out.flush();
        }
        return err;
    };

    if (std.mem.eql(u8, cmd, "list")) {
        return cmdList(&conn, arena, out);
    } else if (std.mem.eql(u8, cmd, "new")) {
        return cmdNew(&conn, arena, out, rest.items[1..]);
    } else if (std.mem.eql(u8, cmd, "kill")) {
        return cmdKill(&conn, out, rest.items[1..]);
    } else if (std.mem.eql(u8, cmd, "peek")) {
        return cmdPeek(&conn, out, rest.items[1..]);
    } else if (std.mem.eql(u8, cmd, "rename")) {
        return cmdRename(&conn, arena, out, rest.items[1..]);
    } else if (std.mem.eql(u8, cmd, "rm-session")) {
        return cmdRmSession(&conn, arena, out, rest.items[1..]);
    } else if (std.mem.eql(u8, cmd, "attach")) {
        try out.flush();
        return cmdAttach(&conn, gpa, init.io, rest.items[1..]);
    }

    try out.print("illogical: unknown command '{s}'\n", .{cmd});
}

fn cmdList(conn: *Conn, arena: std.mem.Allocator, out: *Io.Writer) !void {
    try conn.send(.list, protocol.control_session, &.{});
    const frame = try conn.recv();
    if (frame.header.type != .session_list) return error.UnexpectedFrame;

    const parsed = try protocol.body.decode(protocol.body.SessionList, arena, frame.payload);
    const list = parsed.value;

    if (list.terminals.len == 0) {
        try out.writeAll("no terminals\n");
        return;
    }

    // `PTY` is the IO regime: `hot` means this terminal owns an OS thread
    // blocked on `read()`, `polled` means its descriptor is one of many in the
    // server's shared poller. Worth showing, because "how many terminals still
    // cost a thread" is the question A3 exists to answer.
    try out.print("{s:<5} {s:<12} {s:<12} {s:<12} {s:<8} {s:>8} {s:>7}\n", .{
        "ID", "SESSION", "NAME", "RESIDENCY", "PTY", "ATTACHED", "IDLE",
    });
    for (list.terminals) |t| {
        const session_name = for (list.sessions) |s| {
            if (s.id == t.session) break s.name;
        } else "?";
        try out.print("{d:<5} {s:<12} {s:<12} {s:<12} {s:<8} {d:>8} {d:>6}s\n", .{
            t.id,
            session_name,
            t.name,
            t.residency,
            t.regime,
            t.attached,
            t.pty_read_idle_ns / std.time.ns_per_s,
        });
    }
}

fn cmdNew(
    conn: *Conn,
    arena: std.mem.Allocator,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    var session_name: []const u8 = "default";
    var name: []const u8 = "";
    var argv: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-s") and i + 1 < args.len) {
            i += 1;
            session_name = args[i];
        } else if (std.mem.eql(u8, a, "-n") and i + 1 < args.len) {
            i += 1;
            name = args[i];
        } else if (std.mem.eql(u8, a, "--")) {
            try argv.appendSlice(arena, args[i + 1 ..]);
            break;
        } else {
            try argv.appendSlice(arena, args[i..]);
            break;
        }
    }

    try conn.sendJson(.create, protocol.control_session, protocol.body.Create{
        .session_name = session_name,
        .name = name,
        .argv = argv.items,
        .cols = 120,
        .rows = 40,
    });

    const frame = try conn.recv();
    if (frame.header.type == .err) {
        const e = try protocol.body.decode(protocol.body.Err, arena, frame.payload);
        try out.print("illogical: {s}\n", .{e.value.message});
        return error.CreateFailed;
    }
    const created = try protocol.body.decode(protocol.body.Created, arena, frame.payload);
    try out.print("{d}\n", .{created.value.terminal});
}

fn cmdKill(conn: *Conn, out: *Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) {
        try out.writeAll("usage: illogical kill <terminal-id>\n");
        return error.InvalidArgs;
    }
    const id = try std.fmt.parseInt(u64, args[0], 10);
    try conn.sendJson(.kill, id, protocol.body.Kill{});
}

fn cmdPeek(conn: *Conn, out: *Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) {
        try out.writeAll("usage: illogical peek <terminal-id>\n");
        return error.InvalidArgs;
    }
    const id = try std.fmt.parseInt(u64, args[0], 10);
    try conn.sendJson(.peek, id, protocol.body.Peek{});

    const frame = try conn.recv();
    if (frame.header.type != .screen) return error.UnexpectedFrame;
    try out.writeAll(frame.payload);
    if (frame.payload.len > 0 and frame.payload[frame.payload.len - 1] != '\n') {
        try out.writeAll("\n");
    }
}

/// The two session-scoped commands. Both put the session id in the body,
/// because the frame header's u64 addresses a *terminal*.
fn cmdRename(
    conn: *Conn,
    arena: std.mem.Allocator,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 2) {
        try out.writeAll("usage: illogical rename <session-id> <name>\n");
        return error.InvalidArgs;
    }
    const id = try std.fmt.parseInt(u64, args[0], 10);
    try conn.sendJson(.rename_session, protocol.control_session, protocol.body.RenameSession{
        .session = id,
        .name = args[1],
    });
    return expectAck(conn, arena, out);
}

fn cmdRmSession(
    conn: *Conn,
    arena: std.mem.Allocator,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    const usage_line = "usage: illogical rm-session [--if-empty] <session-id>\n";
    var only_if_empty = false;
    var id_arg: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--if-empty")) {
            only_if_empty = true;
        } else if (id_arg == null) {
            id_arg = a;
        } else {
            // One session, spelled once. Swallowing a second positional would
            // make `rm-session 1 2` delete session 1 and say nothing at all
            // about session 2 -- a destructive command is the last place to
            // guess at what somebody meant.
            try out.writeAll(usage_line);
            return error.InvalidArgs;
        }
    }
    const raw = id_arg orelse {
        try out.writeAll(usage_line);
        return error.InvalidArgs;
    };
    const id = try std.fmt.parseInt(u64, raw, 10);
    try conn.sendJson(.delete_session, protocol.control_session, protocol.body.DeleteSession{
        .session = id,
        .only_if_empty = only_if_empty,
    });
    return expectAck(conn, arena, out);
}

/// Wait for the server to have finished with the frame just sent, and report
/// its refusal if there was one.
///
/// Neither session-scoped frame has a reply of its own: success is the
/// `sessions_changed` broadcast, which is addressed to nobody and, for a
/// delete, does not go out until the children have actually exited. A `ping`
/// behind the request is an in-order barrier instead -- one reader thread
/// dispatches both and everything it queues stays in order -- so a `pong`
/// means "accepted" and an `err` ahead of it is the objection. Broadcasts that
/// arrive in between are somebody else's news.
fn expectAck(conn: *Conn, arena: std.mem.Allocator, out: *Io.Writer) !void {
    try conn.send(.ping, protocol.control_session, &.{});
    while (true) {
        const frame = try conn.recv();
        switch (frame.header.type) {
            .pong => return,
            .err => {
                const e = try protocol.body.decode(protocol.body.Err, arena, frame.payload);
                try out.print("illogical: {s}\n", .{e.value.message});
                return error.RequestRefused;
            },
            else => continue,
        }
    }
}

fn defaultSocketPath(alloc: std.mem.Allocator) ![]u8 {
    if (sys.getenv("ILLOGICAL_SOCK")) |p| return alloc.dupe(u8, p);
    if (sys.getenv("XDG_STATE_HOME")) |state| {
        return std.fmt.allocPrint(alloc, "{s}/illogical/server.sock", .{state});
    }
    const home = sys.getenv("HOME") orelse "/tmp";
    return std.fmt.allocPrint(alloc, "{s}/.local/state/illogical/server.sock", .{home});
}

const attach = @import("attach.zig");
const cmdAttach = attach.run;

test {
    _ = illogical;
    _ = attach;
}
