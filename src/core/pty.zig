//! PTY allocation and child spawning.
//!
//! Deliberately thin: the daemon owns the master fd and reads it on a dedicated
//! thread. Nothing here interprets the byte stream — that is libghostty-vt's
//! job.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const thread = @import("thread.zig");

const log = std.log.scoped(.pty);

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    if (builtin.os.tag.isDarwin()) {
        @cInclude("util.h");
        @cInclude("xlocale.h");
    } else {
        @cInclude("pty.h");
        @cInclude("locale.h");
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

const base_env = [_]Pty.EnvPair{
    .{ .name = "TERM", .value = "xterm-ghostty" },
    .{ .name = "TERM_PROGRAM", .value = "illogical" },
    .{ .name = "COLORTERM", .value = "truecolor" },
};

// -- the child's locale ----------------------------------------------------
//
// Whether the daemon has a locale of its own depends entirely on how it was
// started: a shell exports LANG, launchd and a .app bundle do not. Since
// `spawn` applies `base_env` over the inherited environment, a daemon started
// without one would leave every child in the C locale, and the client's VT
// engine decodes UTF-8 and nothing else -- so a shell whose line editor emits
// Latin-1 draws mojibake in every terminal of every session.
//
// The daemon itself never needs a locale; it moves PTY bytes without
// interpreting them. So, unlike Ghostty, we do not `setlocale` on ourselves --
// we only make sure the child's environment asks for UTF-8.

/// Where the child's `LC_CTYPE` comes from, in POSIX precedence order. That is
/// the only category we have an opinion about: it is the one that decides how
/// the child encodes the text it writes.
const ctype_vars = [_][:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" };

/// Tried in order when the environment names no UTF-8 locale and has no
/// language worth keeping. `en_US.UTF-8` is present on every macOS and is the
/// locale Ghostty falls back to; `C.UTF-8` covers the Linux hosts that generate
/// no locales but ship it built in; bare `UTF-8` is a macOS-only spelling of
/// last resort. Whichever this machine can actually load first wins.
const utf8_fallbacks = [_][:0]const u8{ "en_US.UTF-8", "C.UTF-8", "UTF-8" };

var env_mutex: thread.Mutex = .{};
var env_storage: [base_env.len + 1]Pty.EnvPair = undefined;
var env_len: ?usize = null;
var locale_buf: [64]u8 = undefined;

/// Environment every terminal's child gets, on top of the daemon's own.
///
/// Resolved once, on first use: the locale part of it depends both on the
/// daemon's own environment and on which locales this machine has installed.
pub fn childEnv() []const Pty.EnvPair {
    env_mutex.lock();
    defer env_mutex.unlock();

    if (env_len == null) {
        @memcpy(env_storage[0..base_env.len], &base_env);
        var len: usize = base_env.len;

        var current: [ctype_vars.len]?[]const u8 = undefined;
        for (ctype_vars, 0..) |name, i| current[i] = sys.getenv(name.ptr);
        if (utf8Ctype(current, localeExists, &locale_buf)) |pair| {
            // `utf8Ctype` asks for UTF-8 even when it ran out of candidates, so
            // that the intent is at least visible in the child's environment.
            // Say so here rather than leave the mojibake a mystery.
            if (!localeExists(std.mem.span(pair.value))) {
                log.warn(
                    "no UTF-8 locale installed; setting {s}={s} anyway, but the child will fall back to C",
                    .{ std.mem.span(pair.name), std.mem.span(pair.value) },
                );
            }
            env_storage[len] = pair;
            len += 1;
        }

        env_len = len;
    }

    return env_storage[0..env_len.?];
}

/// The locale variable a child needs set so that its `LC_CTYPE` selects UTF-8,
/// or null when the environment it inherits already gets that right.
///
/// `current` holds the daemon's own value for each of `ctype_vars`, `exists`
/// reports whether libc can load a locale name on this machine, and `buf` backs
/// the returned value.
fn utf8Ctype(
    current: [ctype_vars.len]?[]const u8,
    exists: *const fn (name: [:0]const u8) bool,
    buf: []u8,
) ?Pty.EnvPair {
    // POSIX: a variable that is set but empty does not select anything.
    const winner: ?usize = for (current, 0..) |value, i| {
        if (value) |v| if (v.len > 0) break i;
    } else null;

    // Already UTF-8. Leave it alone, so whoever runs the daemon as de_DE.UTF-8
    // keeps their language rather than being handed ours.
    if (winner) |i| if (isUtf8(current[i].?)) return null;

    // Override whichever variable won; setting one below it would be ignored.
    // With nothing set at all, LANG is the right place to put it -- it is the
    // one the other two are meant to override.
    const name = if (winner) |i| ctype_vars[i] else "LANG";

    // Prefer the same language and region with the charset swapped, so that
    // de_DE.ISO8859-1 stays German and a bare C becomes C.UTF-8.
    if (winner) |i| {
        const value = current[i].?;
        const language = value[0..(std.mem.indexOfScalar(u8, value, '.') orelse value.len)];
        if (std.fmt.bufPrintZ(buf, "{s}.UTF-8", .{language})) |candidate| {
            if (exists(candidate)) return .{ .name = name.ptr, .value = candidate.ptr };
        } else |_| {}
    }

    for (utf8_fallbacks) |candidate| {
        if (exists(candidate)) return .{ .name = name.ptr, .value = candidate.ptr };
    }

    // No UTF-8 locale on this machine at all. Ask for one anyway: it leaves the
    // child no worse off than the C locale we would otherwise have left in
    // place, and it puts the intent somewhere a person can see. `childEnv`
    // notices and logs it; this stays pure so the tests can drive it.
    return .{ .name = name.ptr, .value = utf8_fallbacks[0].ptr };
}

/// Whether a locale name selects the UTF-8 charset. `de_DE.UTF-8`, `de_DE.utf8`
/// and `sr_RS.UTF-8@latin` all do; `C` and `de_DE.ISO8859-1` do not.
fn isUtf8(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    var charset = name[dot + 1 ..];
    if (std.mem.indexOfScalar(u8, charset, '@')) |at| charset = charset[0..at];

    // "UTF-8", "UTF8" and "utf8" are all the same charset.
    var normalized: [8]u8 = undefined;
    var len: usize = 0;
    for (charset) |ch| {
        if (ch == '-') continue;
        if (len == normalized.len) return false;
        normalized[len] = std.ascii.toLower(ch);
        len += 1;
    }
    return std.mem.eql(u8, normalized[0..len], "utf8");
}

/// Whether this machine's libc can load `name`. A LANG naming a locale that is
/// not installed leaves the child in the C locale -- the very thing we are
/// fixing -- so every candidate is checked before it is handed over.
fn localeExists(name: [:0]const u8) bool {
    const locale = c.newlocale(c.LC_CTYPE_MASK, name.ptr, null) orelse return false;
    _ = c.freelocale(locale);
    return true;
}

/// Stand-ins for whatever locales the machine running the tests happens to
/// have, so the decisions below are the only thing under test.
const fake_locales = struct {
    fn all(_: [:0]const u8) bool {
        return true;
    }

    fn none(_: [:0]const u8) bool {
        return false;
    }

    fn onlyEnglish(name: [:0]const u8) bool {
        return std.mem.eql(u8, name, "en_US.UTF-8");
    }
};

fn expectCtype(pair: ?Pty.EnvPair, name: []const u8, value: []const u8) !void {
    const set = pair orelse return error.TestExpectedLocaleOverride;
    try std.testing.expectEqualStrings(name, std.mem.span(set.name));
    try std.testing.expectEqualStrings(value, std.mem.span(set.value));
}

test "utf-8 charset is recognised however it is spelled" {
    const testing = std.testing;
    try testing.expect(isUtf8("en_US.UTF-8"));
    try testing.expect(isUtf8("en_US.utf8"));
    try testing.expect(isUtf8("C.UTF8"));
    try testing.expect(isUtf8("sr_RS.UTF-8@latin"));
    try testing.expect(!isUtf8("C"));
    try testing.expect(!isUtf8("POSIX"));
    try testing.expect(!isUtf8(""));
    try testing.expect(!isUtf8("de_DE.ISO8859-1"));
    try testing.expect(!isUtf8("ja_JP.eucJP"));
}

test "a daemon with no locale hands the child a utf-8 one" {
    // launchd, or a .app bundle, or any shell that never exported LANG.
    var buf: [64]u8 = undefined;
    const pair = utf8Ctype(.{ null, null, null }, fake_locales.all, &buf);
    try expectCtype(pair, "LANG", "en_US.UTF-8");
}

test "variables that are set but empty count as unset" {
    var buf: [64]u8 = undefined;
    const pair = utf8Ctype(.{ "", "", "" }, fake_locales.all, &buf);
    try expectCtype(pair, "LANG", "en_US.UTF-8");
}

test "a locale that is already utf-8 is inherited untouched" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(
        @as(?Pty.EnvPair, null),
        utf8Ctype(.{ null, null, "de_DE.UTF-8" }, fake_locales.all, &buf),
    );
    try std.testing.expectEqual(
        @as(?Pty.EnvPair, null),
        utf8Ctype(.{ "C.UTF-8", null, "de_DE.ISO8859-1" }, fake_locales.all, &buf),
    );
}

test "a non-utf-8 locale keeps its language" {
    var buf: [64]u8 = undefined;
    const pair = utf8Ctype(.{ null, null, "de_DE.ISO8859-1" }, fake_locales.all, &buf);
    try expectCtype(pair, "LANG", "de_DE.UTF-8");
}

test "the variable that wins posix precedence is the one overridden" {
    // Setting LANG here would change nothing: LC_ALL outranks it.
    var buf: [64]u8 = undefined;
    const pair = utf8Ctype(.{ "C", "fr_FR.UTF-8", "de_DE.UTF-8" }, fake_locales.all, &buf);
    try expectCtype(pair, "LC_ALL", "C.UTF-8");

    const ctype = utf8Ctype(.{ null, "C", "de_DE.UTF-8" }, fake_locales.all, &buf);
    try expectCtype(ctype, "LC_CTYPE", "C.UTF-8");
}

test "a locale name too long to rewrite still yields a utf-8 one" {
    var buf: [64]u8 = undefined;
    const absurd = "x" ** 200 ++ ".ISO8859-1";
    const pair = utf8Ctype(.{ null, null, absurd }, fake_locales.all, &buf);
    try expectCtype(pair, "LANG", "en_US.UTF-8");
}

test "a language this machine lacks falls back to one it has" {
    var buf: [64]u8 = undefined;
    const pair = utf8Ctype(.{ null, null, "de_DE.ISO8859-1" }, fake_locales.onlyEnglish, &buf);
    try expectCtype(pair, "LANG", "en_US.UTF-8");
}

test "with no utf-8 locale installed the intent is still recorded" {
    var buf: [64]u8 = undefined;
    const pair = utf8Ctype(.{ null, null, null }, fake_locales.none, &buf);
    try expectCtype(pair, "LANG", "en_US.UTF-8");
}

test "this machine has a utf-8 locale to fall back on" {
    // Guards the candidate list against a host where none of them load, which
    // would make the fix silently a no-op.
    var found = false;
    for (utf8_fallbacks) |candidate| found = found or localeExists(candidate);
    try std.testing.expect(found);
}

test "childEnv keeps the base environment and adds at most a locale" {
    const env = childEnv();
    try std.testing.expect(env.len >= base_env.len);
    try std.testing.expect(env.len <= base_env.len + 1);
    for (base_env, 0..) |expected, i| {
        try std.testing.expectEqualStrings(
            std.mem.span(expected.name),
            std.mem.span(env[i].name),
        );
    }
    // Idempotent: resolved once and cached.
    try std.testing.expectEqual(env.len, childEnv().len);
}

test "the resolved locale reaches the child" {
    const testing = std.testing;

    // Resolve as if the daemon had been started with no locale at all, then
    // hand the result to a real child and ask it what it got.
    var buf: [64]u8 = undefined;
    const locale = utf8Ctype(.{ null, null, null }, localeExists, &buf).?;
    const env = base_env ++ [_]Pty.EnvPair{locale};

    var p = try Pty.open(.{ .cols = 80, .rows = 24 });
    defer p.deinit();

    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf %s \"$LANG\"" };
    const pid = try p.spawn(&argv, &env, null);

    var out: [256]u8 = undefined;
    var len: usize = 0;
    while (len < out.len) {
        // The slave closing when the child exits ends the read, with EIO on
        // Darwin and end-of-stream on Linux.
        const n = sys.readFd(p.master, out[len..]) catch break;
        if (n == 0) break;
        len += n;
    }
    _ = sys.wait(pid);

    try testing.expectEqualStrings(std.mem.span(locale.value), out[0..len]);
    try testing.expect(isUtf8(out[0..len]));
}

test "open and resize a pty" {
    const testing = std.testing;
    var p = try Pty.open(.{ .cols = 80, .rows = 24 });
    defer p.deinit();
    try testing.expect(p.master >= 0);
    try testing.expect(p.slave >= 0);
    try p.setSize(.{ .cols = 120, .rows = 40 });
    sys.closeFd(p.slave);
}
