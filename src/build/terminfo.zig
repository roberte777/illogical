//! Prints ghostty's terminfo entry, for `tic` to compile.
//!
//! The entry is maintained in Zig inside the ghostty submodule
//! (`src/terminfo/ghostty.zig`), which is where `ghostty +terminfo` gets it
//! too. Reaching into it rather than checking a copy of the source in here is
//! the point: the database we ship then describes the pin we build against,
//! and cannot drift from the VT that is actually drawing the terminal.

const std = @import("std");
const terminfo = @import("ghostty-terminfo");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    try terminfo.ghostty.encode(&stdout.interface);
    try stdout.interface.flush();
}
