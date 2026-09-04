//! illogical — control CLI for illogicald.
//!
//! Speaks the same protocol as the GUI clients. `illogical attach` is a plain
//! terminal client for when you are already inside a terminal; the Mac app is
//! for when you are not.

const std = @import("std");
const Io = std.Io;
const illogical = @import("illogical");

const usage =
    \\illogical — control a running illogicald
    \\
    \\Usage: illogical <command> [args]
    \\
    \\Commands:
    \\  list                 List sessions and their residency
    \\  new [-n name] [cmd]  Create a session
    \\  attach <session>     Attach the current terminal to a session
    \\  kill <session>       Terminate a session
    \\  doctor               Report server health and park-store stats
    \\
    \\Options:
    \\  --socket <path>      Control socket to connect to
    \\  --version            Print version and exit
    \\  --help               Print this help and exit
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    if (args.len < 2) {
        try out.writeAll(usage);
        return out.flush();
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try out.writeAll(usage);
        return out.flush();
    }
    if (std.mem.eql(u8, cmd, "--version")) {
        try out.print("illogical {s}\n", .{illogical.version});
        return out.flush();
    }

    try out.print(
        "illogical: '{s}' is not implemented yet (see docs/ROADMAP.md)\n",
        .{cmd},
    );
    try out.flush();
}

test {
    _ = illogical;
}
