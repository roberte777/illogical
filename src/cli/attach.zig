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

    const size = terminalSize(sys.STDOUT);
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

    // The terminal above us can be resized at any point from here on, and the
    // PTY on the far side only hears about it because we say so. Not for a
    // pipe: `illogical attach 3 </dev/null >log` is never sent a SIGWINCH, and
    // need not carry a thread and a pipe waiting for one.
    if (winSize(sys.STDOUT) != null) {
        watchWindowSize(conn, id) catch |err| {
            std.log.warn("resizing this terminal will not resize the session: {t}", .{err});
        };
    }
    defer unwatchWindowSize();

    // stdin -> server, on its own thread. Writes are serialised by the
    // connection itself, so the resize loop below shares it safely.
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
            // Every attached client is sent this, and for a passthrough there
            // is nothing in it to do: the grid it marks belongs to the
            // terminal we are running inside, which reflowed itself when its
            // window moved and does not need telling. A client with a mirror
            // of its own reflows here; we have none. See PROTOCOL.md.
            .resized => {},
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

/// The size `fd` reports, in the shape the daemon is told, or null when it is
/// not a terminal.
///
/// Separate from `terminalSize` because the answer "there is no terminal here"
/// is worth having on its own: it is what decides whether following SIGWINCH
/// is worth a thread.
fn winSize(fd: sys.fd_t) ?protocol.body.Attach {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(fd, c.TIOCGWINSZ, &ws) != 0 or ws.ws_col == 0) return null;
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

/// The terminal this is running in, with the size one that will not say gets
/// anyway.
///
/// Takes the descriptor rather than assuming `STDOUT` so a test can point it
/// at a PTY whose `winsize` it sets itself.
fn terminalSize(fd: sys.fd_t) protocol.body.Attach {
    return winSize(fd) orelse .{ .cols = 80, .rows = 24 };
}

// -- following the terminal's size ------------------------------------------

/// Raised by the SIGWINCH handler, lowered by `ResizeWatch.loop`.
var resize_pending: std.atomic.Value(bool) = .init(false);

/// The write end of the pipe the handler pokes, or -1 before there is one.
var resize_wake: std.atomic.Value(sys.fd_t) = .init(-1);

/// Everything the resize thread needs, so that the loop is a plain function
/// over its inputs and a test can run it without a signal or a real terminal.
const ResizeWatch = struct {
    conn: *Conn,
    id: u64,
    /// The terminal whose size we follow -- `STDOUT`, or a PTY under test.
    tty: sys.fd_t,
    /// The read end of the pipe the handler pokes.
    wake: sys.fd_t,

    /// Send the terminal's size whenever the handler says it moved.
    ///
    /// Ends when the write end of the pipe is closed, or when the connection
    /// stops taking frames -- which is the same thing that ends the two loops
    /// either side of it.
    fn loop(self: ResizeWatch) void {
        // Room for more than one wake, because a drag delivers a run of them
        // and there is no reason to make a syscall each.
        var drain: [64]u8 = undefined;
        while (true) {
            const n = sys.readFd(self.wake, &drain) catch break;
            if (n == 0) break;
            // Lowered *before* the size is read, never after. A signal that
            // lands in between leaves the flag up and a byte behind it, so the
            // next turn of this loop sends the newer size rather than
            // mistaking it for the one just sent.
            if (!resize_pending.swap(false, .acquire)) continue;
            self.send() catch break;
        }
    }

    fn send(self: ResizeWatch) !void {
        const size = terminalSize(self.tty);
        try self.conn.sendJson(.resize, self.id, protocol.body.Resize{
            .cols = size.cols,
            .rows = size.rows,
            .cell_width = size.cell_width,
            .cell_height = size.cell_height,
        });
    }
};

/// Start following SIGWINCH, so resizing this terminal resizes the PTY.
///
/// Two pieces, because a signal handler may do almost nothing: it cannot
/// allocate, cannot take the connection's write lock, and certainly cannot
/// speak the protocol. So the handler raises a flag and writes one byte, and a
/// thread blocked on the other end of that pipe does the rest.
///
/// The byte is not redundant with the flag. A thread that only checked the
/// flag would have to check it and *then* block, and a SIGWINCH that arrives
/// between those two is lost: the flag is up, nobody is left to look at it,
/// and the size does not move until the user happens to type. A byte already
/// in the pipe survives that gap -- the read returns at once -- which is what
/// makes resizing the window and doing nothing else enough. The flag is the
/// other half: it collapses a whole drag's worth of signals into one frame.
fn watchWindowSize(conn: *Conn, id: u64) !void {
    const fds = try sys.pipeFds();
    errdefer {
        sys.closeFd(fds[0]);
        sys.closeFd(fds[1]);
    }

    const watch: ResizeWatch = .{ .conn = conn, .id = id, .tty = sys.STDOUT, .wake = fds[0] };
    const thread = try std.Thread.spawn(.{}, ResizeWatch.loop, .{watch});
    thread.detach();

    // The handler must never block, and a full pipe is not a reason to: the
    // bytes already in it mean a wake is already on its way.
    sys.setNonblock(fds[1], true);
    // Published before the handler that reads it, or the first signal finds
    // nothing to poke.
    resize_wake.store(fds[1], .release);

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onWindowChange },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &action, null);
}

/// Stop following, so a SIGWINCH arriving after `run` returns finds nothing of
/// ours. SIGWINCH's default disposition is to be ignored, which is what we
/// want back.
///
/// The pipe stays open on purpose. The loop thread is detached and still
/// blocked on it, and closing the write end here would hand its number to the
/// next `open` while a handler that has only just been uninstalled could still
/// be part-way through writing into it.
fn unwatchWindowSize() void {
    const default: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &default, null);
}

fn onWindowChange(_: std.c.SIG) callconv(.c) void {
    // A handler that leaves `errno` somewhere else corrupts whatever call it
    // interrupted, which here is a `read` on stdin or on the connection.
    const saved = std.c._errno().*;
    defer std.c._errno().* = saved;

    resize_pending.store(true, .release);

    const fd = resize_wake.load(.acquire);
    if (fd < 0) return;
    // One byte, and what becomes of it does not matter: a pipe that will not
    // take it is a pipe with a wake already in it.
    _ = sys.writeFd(fd, &[_]u8{0}) catch return;
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

test "the cell comes out of the winsize the terminal reports" {
    const testing = std.testing;

    // A PTY stands in for the terminal we are attached from: a `winsize` we
    // set ourselves is the whole of what `terminalSize` reads.
    var pty = try illogical.pty.Pty.open(.{
        .cols = 80,
        .rows = 24,
        .width_px = 800,
        .height_px = 480,
    });
    defer pty.deinit();
    defer sys.closeFd(pty.slave);

    const size = terminalSize(pty.master);
    try testing.expectEqual(@as(u16, 80), size.cols);
    try testing.expectEqual(@as(u16, 24), size.rows);
    try testing.expectEqual(@as(u32, 10), size.cell_width);
    try testing.expectEqual(@as(u32, 20), size.cell_height);

    // A terminal that leaves the pixel fields alone -- most of them -- reports
    // the cell the server reads as "unknown" rather than a bogus one.
    try pty.setSize(.{ .cols = 100, .rows = 40 });
    const bare = terminalSize(pty.master);
    try testing.expectEqual(@as(u16, 100), bare.cols);
    try testing.expectEqual(@as(u32, 0), bare.cell_width);
    try testing.expectEqual(@as(u32, 0), bare.cell_height);

    // Not a terminal at all, and so not worth a thread.
    const fds = try sys.pipeFds();
    defer sys.closeFd(fds[0]);
    defer sys.closeFd(fds[1]);
    try testing.expect(winSize(fds[0]) == null);
}

test "a window-size change is sent on as a resize frame" {
    const testing = std.testing;

    var pty = try illogical.pty.Pty.open(.{ .cols = 80, .rows = 24 });
    defer pty.deinit();
    defer sys.closeFd(pty.slave);

    // A pipe for the connection to write frames into, and one for the wake the
    // handler would normally deliver.
    const frames = try sys.pipeFds();
    defer sys.closeFd(frames[0]);
    defer sys.closeFd(frames[1]);
    const wake = try sys.pipeFds();
    defer sys.closeFd(wake[0]);

    var conn: Conn = .{ .read_fd = frames[0], .write_fd = frames[1], .gpa = testing.allocator };
    defer conn.read_buf.deinit(testing.allocator);

    const watch: ResizeWatch = .{ .conn = &conn, .id = 7, .tty = pty.master, .wake = wake[0] };
    const runner = try std.Thread.spawn(.{}, ResizeWatch.loop, .{watch});

    try pty.setSize(.{ .cols = 132, .rows = 43, .width_px = 1320, .height_px = 860 });
    // Exactly what `onWindowChange` does, without needing the signal to be
    // delivered to this particular thread of the test runner.
    resize_pending.store(true, .release);
    try sys.writeAll(wake[1], &[_]u8{0});

    const frame = try conn.recv();

    // A byte with the flag down must produce nothing: that is what keeps a
    // drag from becoming a frame per signal.
    try sys.writeAll(wake[1], &[_]u8{0});
    sys.closeFd(wake[1]);
    runner.join();

    try testing.expectEqual(protocol.FrameType.resize, frame.header.type);
    try testing.expectEqual(@as(u64, 7), frame.header.session);

    const req = try protocol.body.decode(protocol.body.Resize, testing.allocator, frame.payload);
    defer req.deinit();
    try testing.expectEqual(@as(u16, 132), req.value.cols);
    try testing.expectEqual(@as(u16, 43), req.value.rows);
    try testing.expectEqual(@as(u32, 10), req.value.cell_width);
    try testing.expectEqual(@as(u32, 20), req.value.cell_height);

    // Nothing followed it, so the second wake really was collapsed.
    sys.setNonblock(frames[0], true);
    var trailing: [1]u8 = undefined;
    try testing.expectError(error.WouldBlock, sys.readFdOnce(frames[0], &trailing));
}
