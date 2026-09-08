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
    .{ .name = "TERM_PROGRAM", .value = "illogical" },
    .{ .name = "COLORTERM", .value = "truecolor" },
};

// -- the child's terminal type ---------------------------------------------
//
// `xterm-ghostty` is the truthful answer -- the client draws with
// libghostty-vt, so what that entry describes is what a program is talking to
// -- but only on a machine that can look the name up. The entry is not part of
// ncurses: it ships with ghostty, and a machine that has never had ghostty on
// it has never heard of it.
//
// A child told `TERM=xterm-ghostty` there gets no terminfo at all, which is
// much worse than being handed a smaller terminal. With no `cuu1` zsh cannot
// repaint its prompt where it stands: on every SIGWINCH it prints a fresh one
// on a new line and leaves the old one on the screen, so one ⌘D leaves the
// pane with two prompts in it. Measured against the same zsh: under
// `xterm-256color` a resize is answered with `\r\x1b[A\x1b[A\x1b[J` and the
// prompt is redrawn in place; under an unknown `xterm-ghostty` it is answered
// with `\r\r\n` and drawn below.
//
// So: what ghostty itself does (`src/termio/Exec.zig`) -- ship the compiled
// database, point `TERMINFO` at it, and name it in `TERM`. With no database to
// point at, ask for `xterm-256color`, which every machine has.

const term_ghostty = "xterm-ghostty";
const term_fallback = "xterm-256color";

/// Where a database shipped beside the daemon sits, relative to the directory
/// holding it. The Mac app keeps `illogicald` in `Contents/MacOS` and its
/// resources in `Contents/Resources`; the tarball is the usual `bin`/`share`.
const terminfo_bundled = [_][]const u8{
    // The Mac app: `Contents/MacOS/illogicald`, resources one level up.
    "../Resources/terminfo",
    // The tarball, unpacked onto a PATH: the database travels beside the two
    // binaries, because the tarball has no directories in it to speak of.
    "terminfo",
    // `zig build --prefix`, which is what a package manager would install.
    "../share/terminfo",
};

/// Databases already on the machine. Searched only to answer whether the name
/// resolves without our help: a daemon installed by something that is neither
/// the app nor the tarball ships no database of its own, but may be running on
/// a host where ghostty has already put one.
const terminfo_system = [_][]const u8{
    "/usr/share/terminfo",
    "/usr/local/share/terminfo",
    "/opt/homebrew/share/terminfo",
    "/etc/terminfo",
    "/lib/terminfo",
    "/usr/lib/terminfo",
};

/// What the daemon's own environment says about where entries live. The child
/// inherits these, so a database named here is one it can find by itself.
const TerminfoEnv = struct {
    home: ?[]const u8 = null,
    terminfo: ?[]const u8 = null,
    terminfo_dirs: ?[]const u8 = null,
};

/// The terminal type a child is told about, and the database that backs it.
const ChildTerminal = struct {
    term: [:0]const u8,
    /// Set only when the entry was found somewhere the child would not look on
    /// its own -- a database we shipped. Null when it is already on the search
    /// path, or when there is none and `term` is the fallback.
    terminfo: ?[:0]const u8 = null,
};

/// Decide what to tell the child about its terminal.
///
/// `exe_dir` holds this executable, `env` is what the daemon's own environment
/// says about terminfo, `buf` backs the returned path, and `exists` reports
/// whether a path is there. Pure but for `exists`, so a test can lay out a
/// machine that has the entry, or has never heard of it, without one.
fn childTerminal(
    exe_dir: ?[]const u8,
    env: TerminfoEnv,
    buf: []u8,
    exists: *const fn (path: []const u8) bool,
) ChildTerminal {
    // Ours first. A database we shipped is the one that matches the client
    // actually drawing the terminal, and it is the only one we can be sure
    // says what this version says.
    if (exe_dir) |dir| {
        for (terminfo_bundled) |relative| {
            const candidate = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, relative }) catch continue;
            if (terminfoEntryIn(candidate, term_ghostty, exists)) {
                return .{ .term = term_ghostty, .terminfo = candidate };
            }
        }
    }

    // Then wherever the child's own ncurses would look. Nothing to hand it if
    // we find the entry there -- it is already on the path.
    if (terminfoOnSearchPath(env, exists)) return .{ .term = term_ghostty };

    return .{ .term = term_fallback };
}

/// Whether `xterm-ghostty` resolves through the daemon's own environment or
/// the system databases.
fn terminfoOnSearchPath(env: TerminfoEnv, exists: *const fn (path: []const u8) bool) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    if (env.terminfo) |dir| {
        if (terminfoEntryIn(dir, term_ghostty, exists)) return true;
    }
    if (env.home) |home| {
        if (std.fmt.bufPrint(&buf, "{s}/.terminfo", .{home})) |dir| {
            if (terminfoEntryIn(dir, term_ghostty, exists)) return true;
        } else |_| {}
    }
    if (env.terminfo_dirs) |list| {
        var it = std.mem.splitScalar(u8, list, ':');
        while (it.next()) |dir| {
            // ncurses reads an empty element as "the system database", which
            // the loop below covers anyway.
            if (dir.len == 0) continue;
            if (terminfoEntryIn(dir, term_ghostty, exists)) return true;
        }
    }
    for (terminfo_system) |dir| {
        if (terminfoEntryIn(dir, term_ghostty, exists)) return true;
    }
    return false;
}

/// Whether `dir` is a terminfo database holding a compiled entry for `name`.
///
/// Both spellings of the bucket an entry sits in: the entry's first character,
/// which is what ncurses writes on Linux, and that character's hex code, which
/// is what macOS ships (`78/xterm-ghostty`).
fn terminfoEntryIn(
    dir: []const u8,
    name: []const u8,
    exists: *const fn (path: []const u8) bool,
) bool {
    if (name.len == 0) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    if (std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ dir, name[0..1], name })) |path| {
        if (exists(path)) return true;
    } else |_| {}

    const digits = "0123456789abcdef";
    const hex = [_]u8{ digits[name[0] >> 4], digits[name[0] & 0xf] };
    if (std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ dir, &hex, name })) |path| {
        if (exists(path)) return true;
    } else |_| {}

    return false;
}

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
var env_storage: [base_env.len + 3]Pty.EnvPair = undefined;
var env_len: ?usize = null;
var locale_buf: [64]u8 = undefined;
var terminfo_buf: [std.fs.max_path_bytes]u8 = undefined;

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

        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_dir: ?[]const u8 = if (sys.selfExePath(&exe_buf)) |path|
            std.fs.path.dirname(path)
        else |_|
            null;
        const terminal = childTerminal(exe_dir, .{
            .home = sys.getenv("HOME"),
            .terminfo = sys.getenv("TERMINFO"),
            .terminfo_dirs = sys.getenv("TERMINFO_DIRS"),
        }, &terminfo_buf, sys.pathExists);
        env_storage[len] = .{ .name = "TERM", .value = terminal.term.ptr };
        len += 1;
        if (terminal.terminfo) |dir| {
            env_storage[len] = .{ .name = "TERMINFO", .value = dir.ptr };
            len += 1;
            log.info("terminfo database: {s}", .{dir});
        } else if (std.mem.eql(u8, terminal.term, term_fallback)) {
            // Not fatal, and not silent either: it changes what every program
            // in every terminal thinks it is talking to.
            log.warn(
                "no {s} terminfo entry on this machine; children will be told TERM={s}",
                .{ term_ghostty, term_fallback },
            );
        }

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

/// Stand-ins for whatever terminfo databases the machine running the tests has,
/// so that what is under test is where we look and what we conclude.
const fake_terminfo = struct {
    /// A machine with nothing installed anywhere.
    fn none(_: []const u8) bool {
        return false;
    }

    /// A Mac app bundle carrying its own database, macOS's hex bucket and all.
    fn bundled(path: []const u8) bool {
        return std.mem.eql(u8, path, "/Apps/Illogical.app/Contents/MacOS/../Resources/terminfo/78/xterm-ghostty");
    }

    /// The tarball, unpacked onto a PATH.
    fn besideTheBinary(path: []const u8) bool {
        return std.mem.eql(u8, path, "/usr/local/bin/terminfo/78/xterm-ghostty");
    }

    /// A host where somebody has already installed ghostty's entry, in the
    /// per-user database and in ncurses' own spelling of the bucket.
    fn inUsersHome(path: []const u8) bool {
        return std.mem.eql(u8, path, "/home/e/.terminfo/x/xterm-ghostty");
    }

    /// A host with it in the system database.
    fn systemWide(path: []const u8) bool {
        return std.mem.eql(u8, path, "/usr/share/terminfo/78/xterm-ghostty");
    }
};

test "a database beside the daemon is the one the child is pointed at" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const term = childTerminal(
        "/Apps/Illogical.app/Contents/MacOS",
        .{},
        &buf,
        fake_terminfo.bundled,
    );
    try std.testing.expectEqualStrings("xterm-ghostty", term.term);
    try std.testing.expectEqualStrings(
        "/Apps/Illogical.app/Contents/MacOS/../Resources/terminfo",
        term.terminfo orelse return error.TestExpectedTerminfo,
    );
}

test "the tarball's database, beside the two binaries" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const term = childTerminal("/usr/local/bin", .{}, &buf, fake_terminfo.besideTheBinary);
    try std.testing.expectEqualStrings("xterm-ghostty", term.term);
    try std.testing.expectEqualStrings(
        "/usr/local/bin/terminfo",
        term.terminfo orelse return error.TestExpectedTerminfo,
    );
}

test "an entry already on the search path needs no TERMINFO of its own" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // The user's own database, which ncurses reads without being told to.
    const home = childTerminal(null, .{ .home = "/home/e" }, &buf, fake_terminfo.inUsersHome);
    try std.testing.expectEqualStrings("xterm-ghostty", home.term);
    try std.testing.expect(home.terminfo == null);

    // And the system one.
    const system = childTerminal(null, .{}, &buf, fake_terminfo.systemWide);
    try std.testing.expectEqualStrings("xterm-ghostty", system.term);
    try std.testing.expect(system.terminfo == null);
}

test "TERMINFO and TERMINFO_DIRS are searched, empty elements skipped" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const env: TerminfoEnv = .{ .terminfo_dirs = "::/opt/ti:" };
    const term = childTerminal(null, env, &buf, struct {
        fn exists(path: []const u8) bool {
            return std.mem.eql(u8, path, "/opt/ti/x/xterm-ghostty");
        }
    }.exists);
    try std.testing.expectEqualStrings("xterm-ghostty", term.term);
    try std.testing.expect(term.terminfo == null);
}

test "a machine that has never heard of ghostty is told xterm-256color" {
    // The whole point: TERM has to name something the child can look up. An
    // unknown terminal leaves a shell unable to move its own cursor, and it
    // redraws a prompt by printing a second one.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const term = childTerminal("/usr/local/bin", .{ .home = "/home/e" }, &buf, fake_terminfo.none);
    try std.testing.expectEqualStrings("xterm-256color", term.term);
    try std.testing.expect(term.terminfo == null);
}

test "a bundled database wins over one already installed" {
    // Ours describes the pin the client draws with; the machine's describes
    // whichever ghostty happened to be installed.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const term = childTerminal("/usr/local/bin", .{}, &buf, struct {
        fn exists(path: []const u8) bool {
            return fake_terminfo.besideTheBinary(path) or fake_terminfo.systemWide(path);
        }
    }.exists);
    try std.testing.expectEqualStrings(
        "/usr/local/bin/terminfo",
        term.terminfo orelse return error.TestExpectedTerminfo,
    );
}

test "both spellings of a database's bucket are looked in" {
    // ncurses writes `x/xterm-ghostty`; macOS ships `78/xterm-ghostty`.
    try std.testing.expect(terminfoEntryIn("/db", "xterm-ghostty", struct {
        fn exists(path: []const u8) bool {
            return std.mem.eql(u8, path, "/db/x/xterm-ghostty");
        }
    }.exists));
    try std.testing.expect(terminfoEntryIn("/db", "xterm-ghostty", struct {
        fn exists(path: []const u8) bool {
            return std.mem.eql(u8, path, "/db/78/xterm-ghostty");
        }
    }.exists));
    try std.testing.expect(!terminfoEntryIn("/db", "xterm-ghostty", fake_terminfo.none));
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

test "childEnv keeps the base environment and adds what it resolved" {
    const env = childEnv();
    // TERM always, TERMINFO only where a database had to be pointed at, and a
    // locale only where the daemon's own is not UTF-8.
    try std.testing.expect(env.len >= base_env.len + 1);
    try std.testing.expect(env.len <= env_storage.len);
    for (base_env, 0..) |expected, i| {
        try std.testing.expectEqualStrings(
            std.mem.span(expected.name),
            std.mem.span(env[i].name),
        );
    }
    // Idempotent: resolved once and cached.
    try std.testing.expectEqual(env.len, childEnv().len);
}

test "every child is told what terminal it is talking to" {
    // Whichever way it resolved on this machine, the one thing that must not
    // happen is a child left with the daemon's own TERM -- or with none.
    var term: ?[]const u8 = null;
    for (childEnv()) |pair| {
        if (std.mem.eql(u8, std.mem.span(pair.name), "TERM")) term = std.mem.span(pair.value);
    }
    const value = term orelse return error.TestExpectedTerm;
    try std.testing.expect(
        std.mem.eql(u8, value, term_ghostty) or std.mem.eql(u8, value, term_fallback),
    );
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
