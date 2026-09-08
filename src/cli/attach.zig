//! `illogical attach` — the compatibility path.
//!
//! This is the tradeoff Mitchell describes for terminals that cannot speak the
//! protocol: we put a libghostty terminal in the middle. We decode the server's
//! snapshot into a real terminal, format it back out as VT to repaint whatever
//! terminal we are running inside, and then pass live PTY bytes straight
//! through.
//!
//! The Mac client does not do this. It decodes the snapshot into its *own*
//! terminal and renders it, which is the whole point of the architecture.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty = @import("ghostty-vt");
const illogical = @import("illogical");
const protocol = illogical.protocol;
const sys = illogical.sys;
const Conn = illogical.conn.Conn;

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
});

var saved_termios: ?c.termios = null;

pub fn run(conn: *Conn, gpa: Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len < 1) return error.InvalidArgs;
    const id = try std.fmt.parseInt(u64, args[0], 10);

    const size = terminalSize();
    try conn.sendJson(.attach, id, size);

    // A pipe has no termios to put in raw mode, and that is not a reason to
    // refuse. `illogical attach 3 </dev/null >log` is a legitimate thing to
    // want -- it is how the memory benchmark holds fifty connections open --
    // and the rest of this works unchanged without a terminal on either end.
    enterRawMode() catch |err| switch (err) {
        error.NotATerminal => {},
        else => return err,
    };
    defer leaveRawMode();

    // stdin -> server, on its own thread. One writer, as always.
    const feeder = try std.Thread.spawn(.{}, feedInput, .{ conn, id });
    feeder.detach();

    var snapshot: std.ArrayList(u8) = .empty;
    defer snapshot.deinit(gpa);

    while (true) {
        const frame = conn.recv() catch break;
        switch (frame.header.type) {
            .snapshot_begin => snapshot.clearRetainingCapacity(),
            .snapshot_chunk => try snapshot.appendSlice(gpa, frame.payload),
            .snapshot_ready => {
                repaint(gpa, io, snapshot.items, size) catch |err| {
                    std.log.warn("could not repaint from snapshot: {t}", .{err});
                };
            },
            // History pages are not useful to a dumb terminal: it has its own
            // scrollback and we must not scribble into it.
            .snapshot_end => snapshot.clearRetainingCapacity(),
            .output => try sys.writeAll(sys.STDOUT, frame.payload),
            .exited => break,
            .err => break,
            else => {},
        }
    }
}

/// Decode the snapshot into a real terminal, then emit it as VT so the
/// surrounding terminal shows the same screen.
fn repaint(gpa: Allocator, io: std.Io, bytes: []const u8, size: protocol.body.Attach) !void {
    if (bytes.len == 0) return;

    var reader: std.Io.Reader = .fixed(bytes);
    var decoder: ghostty.snapshot.Decoder = .init(&reader);
    var decoded = try decoder.ready(gpa, io, .{
        .max_continuation_bytes = 65 * 1024 * 1024,
    });
    defer decoded.deinit(gpa);
    const term = &(decoded.terminal orelse return error.NoTerminal);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);

    // Home the cursor and clear before repainting, or the old screen shows
    // through underneath.
    try aw.writer.writeAll("\x1b[H\x1b[2J");

    const formatter: ghostty.formatter.TerminalFormatter = .{
        .terminal = term,
        .opts = .{ .emit = .vt, .trim = true },
        .content = .{ .selection = null },
        // Everything the receiving terminal needs to look right: palette,
        // modes, scrolling region, cursor and styles.
        .extra = .all,
        .pin_map = null,
    };
    try formatter.format(&aw.writer);
    buf = aw.toArrayList();

    _ = size;
    try sys.writeAll(sys.STDOUT, buf.items);
}

fn feedInput(conn: *Conn, id: u64) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.readFd(sys.STDIN, &buf) catch break;
        if (n == 0) break;
        conn.send(.input, id, buf[0..n]) catch break;
    }
}

/// The terminal this is running in, in the shape the daemon is told.
fn terminalSize() protocol.body.Attach {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(sys.STDOUT, c.TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0) {
        return .{
            .cols = ws.ws_col,
            .rows = ws.ws_row,
            // Divided out rather than asked for: a `winsize` carries the text
            // area, not the cell. Most terminals leave the pixel fields at
            // zero -- and zero divided by a column count is zero, which is
            // exactly the "unknown" the server wants for them.
            .cell_width = @as(u32, ws.ws_xpixel) / ws.ws_col,
            .cell_height = if (ws.ws_row > 0) @as(u32, ws.ws_ypixel) / ws.ws_row else 0,
        };
    }
    return .{ .cols = 80, .rows = 24 };
}

fn enterRawMode() !void {
    var attrs: c.termios = undefined;
    if (c.tcgetattr(sys.STDIN, &attrs) != 0) return error.NotATerminal;
    saved_termios = attrs;

    var raw = attrs;
    c.cfmakeraw(&raw);
    if (c.tcsetattr(sys.STDIN, c.TCSANOW, &raw) != 0) return error.RawModeFailed;
}

fn leaveRawMode() void {
    if (saved_termios) |*attrs| {
        _ = c.tcsetattr(sys.STDIN, c.TCSANOW, attrs);
        saved_termios = null;
    }
}
