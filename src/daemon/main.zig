//! illogicald — the illogical session server.
//!
//! Owns every PTY, every terminal's state, and the park store. Clients come and
//! go; sessions do not.

const std = @import("std");
const Io = std.Io;
const illogical = @import("illogical");

const usage =
    \\illogicald — the illogical session server
    \\
    \\Usage: illogicald [options]
    \\
    \\Options:
    \\  --socket <path>   Control socket (default: $XDG_STATE_HOME/illogical/server.sock)
    \\  --park-after <s>  Idle seconds before a session is parked (default: 60)
    \\  --foreground      Do not daemonize
    \\  --version         Print version and exit
    \\  --help            Print this help and exit
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.writeAll(usage);
            return out.flush();
        }
        if (std.mem.eql(u8, arg, "--version")) {
            try out.print("illogicald {s}\n", .{illogical.version});
            return out.flush();
        }
    }

    try out.print(
        \\illogicald {s}
        \\
        \\Not implemented yet. See docs/ROADMAP.md — M1 is the session server:
        \\  * libxev loop over PTY masters and the control socket
        \\  * per-session libghostty-vt terminal fed by raw PTY output
        \\  * snapshot-on-idle parking (docs/PARKING.md)
        \\  * the attach handshake (docs/PROTOCOL.md)
        \\
        \\Protocol version {d}, park threshold {d}s.
        \\
    , .{
        illogical.version,
        illogical.protocol.version,
        illogical.park.default_park_after_ns / std.time.ns_per_s,
    });
    try out.flush();
}

test {
    _ = illogical;
}
