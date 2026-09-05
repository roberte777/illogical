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
    \\
    \\Options:
    \\  --socket <path>          Control socket to connect to
    \\  --version                Print version and exit
    \\  --help                   Print this help and exit
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.writeAll(usage);
        return;
    }

    // Global options may appear anywhere.
    var socket_path: ?[]const u8 = null;
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--socket") and i + 1 < args.len) {
            i += 1;
            socket_path = args[i];
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

    const path = socket_path orelse try defaultSocketPath(arena);
    var conn = Conn.connect(gpa, path) catch |err| {
        try out.print(
            "illogical: cannot reach a server at {s} ({t})\n" ++
                "           start one with: illogicald\n",
            .{ path, err },
        );
        try out.flush();
        return error.NoServer;
    };
    defer conn.deinit();
    _ = try conn.hello(arena, "illogical-cli");

    if (std.mem.eql(u8, cmd, "list")) {
        return cmdList(&conn, arena, out);
    } else if (std.mem.eql(u8, cmd, "new")) {
        return cmdNew(&conn, arena, out, rest.items[1..]);
    } else if (std.mem.eql(u8, cmd, "kill")) {
        return cmdKill(&conn, out, rest.items[1..]);
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

    try out.print("{s:<5} {s:<12} {s:<12} {s:<12} {s:>8} {s:>7}\n", .{
        "ID", "SESSION", "NAME", "RESIDENCY", "ATTACHED", "IDLE",
    });
    for (list.terminals) |t| {
        const session_name = for (list.sessions) |s| {
            if (s.id == t.session) break s.name;
        } else "?";
        try out.print("{d:<5} {s:<12} {s:<12} {s:<12} {d:>8} {d:>6}s\n", .{
            t.id,
            session_name,
            t.name,
            t.residency,
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
