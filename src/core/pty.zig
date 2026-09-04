//! PTY allocation and child spawning.
//!
//! Deliberately thin: the daemon owns the master fd and reads it on a dedicated
//! thread. Nothing here interprets the byte stream — that is libghostty-vt's
//! job.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    if (builtin.os.tag.isDarwin()) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
});

pub const WinSize = struct {
    cols: u16,
    rows: u16,
    /// Pixel dimensions, forwarded so that programs using the terminal's
    /// graphics protocols size themselves correctly.
    width_px: u16 = 0,
    height_px: u16 = 0,

    fn toC(self: WinSize) c.struct_winsize {
        return .{
            .ws_col = self.cols,
            .ws_row = self.rows,
            .ws_xpixel = self.width_px,
            .ws_ypixel = self.height_px,
        };
    }
};

pub const OpenError = error{OpenptyFailed};
pub const SetSizeError = error{IoctlFailed};
pub const SpawnError = error{ ForkFailed, ExecFailed };

/// A terminal's PTY pair. The daemon holds the master; the slave is handed to
/// the child and closed in the parent once the child is running.
pub const Pty = struct {
    master: sys.fd_t,
    slave: sys.fd_t,

    pub fn open(size: WinSize) OpenError!Pty {
        var ws = size.toC();
        var master: c_int = undefined;
        var slave: c_int = undefined;
        if (c.openpty(&master, &slave, null, null, &ws) < 0) return error.OpenptyFailed;
        errdefer {
            sys.closeFd(master);
            sys.closeFd(slave);
        }

        // Only the slave should be inherited by the child.
        sys.setCloexec(master);

        // Enable UTF-8 mode. On by default on Linux, not on macOS.
        var attrs: c.termios = undefined;
        if (c.tcgetattr(master, &attrs) == 0) {
            attrs.c_iflag |= c.IUTF8;
            _ = c.tcsetattr(master, c.TCSANOW, &attrs);
        }

        return .{ .master = master, .slave = slave };
    }

    pub fn deinit(self: *Pty) void {
        sys.closeFd(self.master);
        self.* = undefined;
    }

    pub fn setSize(self: Pty, size: WinSize) SetSizeError!void {
        const ws = size.toC();
        if (c.ioctl(self.master, c.TIOCSWINSZ, &ws) < 0) return error.IoctlFailed;
    }

    pub const EnvPair = struct { name: [*:0]const u8, value: [*:0]const u8 };

    /// Fork and exec `argv` with the slave as the child's controlling terminal.
    /// Closes the slave in the parent on success.
    ///
    /// `argv` must be a null-terminated array of null-terminated strings, as
    /// `execvp` expects. `env` is applied over the inherited environment in the
    /// child, so callers only specify what they want to override.
    pub fn spawn(
        self: *Pty,
        argv: [*:null]const ?[*:0]const u8,
        env: []const EnvPair,
        cwd: ?[*:0]const u8,
    ) SpawnError!sys.pid_t {
        const pid = sys.forkProcess() catch return error.ForkFailed;
        if (pid == 0) {
            // Child. Nothing here may allocate or return.
            self.childPreExec(cwd) catch sys.exitProcess(1);
            for (env) |kv| sys.setenvVar(kv.name, kv.value);
            sys.exec(argv[0].?, argv);
            sys.exitProcess(1);
        }

        // Parent: the child owns the slave now.
        sys.closeFd(self.slave);
        self.slave = -1;
        return pid;
    }

    /// Runs in the forked child before exec.
    fn childPreExec(self: Pty, cwd: ?[*:0]const u8) !void {
        // New session, so the slave can become our controlling terminal.
        if (!sys.newSession()) return error.ProcessGroupFailed;
        if (c.ioctl(self.slave, c.TIOCSCTTY, @as(c_ulong, 0)) < 0) {
            return error.SetControllingTerminalFailed;
        }

        sys.dup2Fd(self.slave, sys.STDIN);
        sys.dup2Fd(self.slave, sys.STDOUT);
        sys.dup2Fd(self.slave, sys.STDERR);
        if (self.slave > sys.STDERR) sys.closeFd(self.slave);
        sys.closeFd(self.master);

        if (cwd) |dir| sys.chdirPath(dir);
    }
};

/// Environment every terminal's child gets, on top of the daemon's own.
pub const base_env = [_]Pty.EnvPair{
    .{ .name = "TERM", .value = "xterm-ghostty" },
    .{ .name = "TERM_PROGRAM", .value = "illogical" },
    .{ .name = "COLORTERM", .value = "truecolor" },
};

test "open and resize a pty" {
    const testing = std.testing;
    var p = try Pty.open(.{ .cols = 80, .rows = 24 });
    defer p.deinit();
    try testing.expect(p.master >= 0);
    try testing.expect(p.slave >= 0);
    try p.setSize(.{ .cols = 120, .rows = 40 });
    sys.closeFd(p.slave);
}
