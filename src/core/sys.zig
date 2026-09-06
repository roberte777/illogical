//! The libc surface the daemon needs.
//!
//! Zig 0.16 removed most of `std.posix` in favour of `std.Io`, but the server's
//! hot path is deliberately *not* evented (see docs/ARCHITECTURE.md): a hot PTY
//! owns a thread blocked on `read()`. So we declare what we need directly. One
//! module, explicit, and immune to further stdlib churn.

const std = @import("std");
const builtin = @import("builtin");
const thread = @import("thread.zig");

pub const fd_t = std.c.fd_t;
pub const pid_t = std.c.pid_t;
pub const socklen_t = std.c.socklen_t;
pub const sockaddr = std.c.sockaddr;

pub const AF_UNIX: c_uint = 1;
pub const SOCK_STREAM: c_uint = if (builtin.os.tag == .linux) 1 else 1;
pub const F_GETFD: c_int = 1;
pub const F_SETFD: c_int = 2;
pub const F_GETFL: c_int = 3;
pub const F_SETFL: c_int = 4;
/// Duplicate onto the lowest free descriptor at or above the argument.
pub const F_DUPFD: c_int = 0;
pub const FD_CLOEXEC: c_int = 1;
pub const O_NONBLOCK: c_int = if (builtin.os.tag == .linux) 0o4000 else 4;

extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
extern "c" fn bind(sockfd: fd_t, addr: *const sockaddr, len: socklen_t) c_int;
extern "c" fn listen(sockfd: fd_t, backlog: c_uint) c_int;
extern "c" fn accept(sockfd: fd_t, addr: ?*sockaddr, len: ?*socklen_t) c_int;
extern "c" fn connect(sockfd: fd_t, addr: *const sockaddr, len: socklen_t) c_int;
extern "c" fn shutdown(sockfd: fd_t, how: c_int) c_int;
extern "c" fn close(fd: fd_t) c_int;
extern "c" fn read(fd: fd_t, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: fd_t, buf: [*]const u8, n: usize) isize;
extern "c" fn fork() pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: pid_t, status: ?*c_int, options: c_int) pid_t;
extern "c" fn dup2(old: fd_t, new: fd_t) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn setsid() pid_t;
extern "c" fn kill(pid: pid_t, sig: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn fcntl(fd: fd_t, cmd: c_int, ...) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn pipe(fds: *[2]fd_t) c_int;
extern "c" fn getdtablesize() c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, size: usize) isize;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

pub const Error = error{
    SocketFailed,
    BindFailed,
    ListenFailed,
    AcceptFailed,
    ConnectFailed,
    ReadFailed,
    WriteFailed,
    ForkFailed,
    NameTooLong,
    /// A signal arrived while the call was blocked. Only `readFdOnce` reports
    /// this; everything else retries.
    Interrupted,
    /// Nothing to read on a non-blocking descriptor.
    WouldBlock,
    PipeFailed,
    OpenFailed,
    /// This process cannot say where its own executable is. See `selfExePath`.
    NoSelfExe,
};

pub fn errno() c_int {
    return std.c._errno().*;
}

const EINTR: c_int = 4;
const EAGAIN: c_int = if (builtin.os.tag == .linux) 11 else 35;

pub const STDIN = 0;
pub const STDOUT = 1;
pub const STDERR = 2;

pub fn closeFd(fd: fd_t) void {
    _ = close(fd);
}

pub fn readFd(fd: fd_t, buf: []u8) Error!usize {
    while (true) {
        return readFdOnce(fd, buf) catch |err| switch (err) {
            // A signal arrived, not a failure.
            error.Interrupted => continue,
            else => return err,
        };
    }
}

/// One `read`, reporting a signal rather than swallowing it.
///
/// This is what a hot PTY reader blocks in. The distinction matters there and
/// nowhere else: interrupting that blocking read is the only way to get the
/// descriptor back so it can migrate to the shared poller, and a retry loop
/// inside here would hide the interruption and go straight back to sleep. See
/// docs/OPTIMIZATIONS.md A3.
pub fn readFdOnce(fd: fd_t, buf: []u8) Error!usize {
    const n = read(fd, buf.ptr, buf.len);
    if (n >= 0) return @intCast(n);
    return switch (errno()) {
        EINTR => error.Interrupted,
        EAGAIN => error.WouldBlock,
        else => error.ReadFailed,
    };
}

pub fn writeFd(fd: fd_t, buf: []const u8) Error!usize {
    while (true) {
        const n = write(fd, buf.ptr, buf.len);
        if (n >= 0) return @intCast(n);
        if (errno() == EINTR) continue;
        return error.WriteFailed;
    }
}

pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) off += try writeFd(fd, bytes[off..]);
}

/// Fill `buf` completely or fail. Returns error.ReadFailed at end of stream.
pub fn readAll(fd: fd_t, buf: []u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try readFd(fd, buf[off..]);
        if (n == 0) return error.ReadFailed;
        off += n;
    }
}

pub fn setCloexec(fd: fd_t) void {
    const flags = fcntl(fd, F_GETFD);
    if (flags == -1) return;
    _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

pub fn clearCloexec(fd: fd_t) void {
    const flags = fcntl(fd, F_GETFD);
    if (flags == -1) return;
    _ = fcntl(fd, F_SETFD, flags & ~FD_CLOEXEC);
}

/// Duplicate `fd` onto the lowest free descriptor at or above `lowest`.
///
/// For a caller that needs a descriptor in a *particular range* rather than
/// wherever `open` happened to put it, without `dup2`'s habit of silently
/// closing whatever was already on the target.
pub fn dupFrom(fd: fd_t, lowest: fd_t) Error!fd_t {
    const next = fcntl(fd, F_DUPFD, lowest);
    if (next < 0) return error.OpenFailed;
    return next;
}

/// Close every descriptor from `lowest` upward.
///
/// For a forked child that is about to become a long-lived daemon: it inherits
/// everything its parent had open that was not marked close-on-exec, and a
/// daemon started by `illogicald --stdio` outlives the SSH session by days,
/// handing each one on to every shell it ever spawns. `~/.ssh/rc` or an
/// `authorized_keys command=` wrapper that opens a log or a credential file
/// before exec'ing us is enough to leak one.
///
/// A loop rather than `closefrom`/`close_range`, which differ between macOS
/// and Linux and by version. `close` is async-signal-safe, which is what makes
/// this legal between `fork` and `exec`.
pub fn closeFrom(lowest: fd_t) void {
    // Clamped, because `getdtablesize` is the *soft* `RLIMIT_NOFILE` and that
    // is the caller's environment to set: it can be 2^30 under a service
    // manager, where the loop would run for minutes between `fork` and `exec`
    // and the bridge would give up waiting for a daemon that turns up anyway.
    //
    // An ordinary mac reads 138,240 here and a distro sshd is typically
    // configured to 65,536, both well under the ceiling. It was 4096 before,
    // which is *below* both -- so on the systemd `LimitNOFILE=65536`
    // configuration this function's own doc comment describes, anything the
    // ssh wrapper had parked at a high descriptor survived into the daemon.
    //
    // A failing `close` measured ~96ns here, so the full million is ~100ms on
    // this machine and several times that on an x86-64 kernel with mitigations
    // -- which a container reaches routinely rather than pathologically, since
    // Docker's default is exactly 1,048,576. Nobody waits on it: this runs
    // between `fork` and `exec` in a child, and the parent's own timeout for
    // the daemon to appear is ten seconds.
    //
    // Still best-effort, and the clamp is not the only reason: `getdtablesize`
    // is the soft limit *now*, so a wrapper that opens a descriptor and then
    // lowers `ulimit -n` before exec'ing us leaves it above the limit and
    // therefore untouched.
    const limit = @min(getdtablesize(), 1 << 20);
    var fd = lowest;
    while (fd < limit) : (fd += 1) _ = close(fd);
}

/// Create `path` and any missing parents, like `mkdir -p`. Best effort.
///
/// `std.Io.Dir.createDirPath` needs an `Io`, and the one caller is about to
/// `fork`: the bridge has to make the daemon's state directory *before* the
/// grandchild tries to open a log inside it, because the daemon does not
/// create that directory until it is already running.
///
/// 0700 because of what ends up in there: the park store, a terminal's
/// scrollback and the key it is encrypted with. Only a preference, though --
/// the daemon creates this same directory itself through
/// `std.Io.Dir.createDirPath`, which is 0777 before umask, so on a host where
/// `illogicald` was ever started by hand the mode is whatever that left. The
/// protection that does not depend on who got there first is the key file's
/// own 0600, in crypt.zig.
pub fn makeDirPath(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len == 0 or path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    // Each prefix in turn, so missing intermediates are created too. Failures
    // are ignored: the usual one is EEXIST, and a real one surfaces when the
    // caller opens the file.
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and buf[i] != '/') continue;
        const saved = buf[i];
        buf[i] = 0;
        _ = mkdir(@ptrCast(&buf), 0o700);
        buf[i] = saved;
    }
}

/// Turn non-blocking mode on or off.
///
/// A PTY toggles this as it migrates between IO regimes: blocking while a
/// dedicated thread is parked in `read()` on it, non-blocking once it is one
/// of many descriptors in the shared poller, where a `read` that turned out to
/// have nothing behind it would stall every other terminal.
pub fn setNonblock(fd: fd_t, on: bool) void {
    _ = trySetNonblock(fd, on);
}

/// The same, reporting whether it took.
///
/// For the one caller that cannot proceed without it: a "non-blocking" drain
/// on a descriptor that is still blocking is an unbounded wait on a child that
/// may never write again, which is precisely what the caller's deadline exists
/// to prevent. Everything else toggles a descriptor it just created and has
/// nothing to do about a failure, so `setNonblock` stays void.
pub fn trySetNonblock(fd: fd_t, on: bool) bool {
    const flags = fcntl(fd, F_GETFL);
    if (flags == -1) return false;
    const next = if (on) flags | O_NONBLOCK else flags & ~O_NONBLOCK;
    return fcntl(fd, F_SETFL, next) != -1;
}

/// A pipe, used only to wake a thread blocked in the poller.
pub fn pipeFds() Error![2]fd_t {
    var fds: [2]fd_t = undefined;
    if (pipe(&fds) < 0) return error.PipeFailed;
    setCloexec(fds[0]);
    setCloexec(fds[1]);
    return fds;
}

const O_RDWR: c_int = 2;

/// `/dev/null`, opened read-write.
///
/// Deliberately not close-on-exec: the one caller is a forked child about to
/// `dup2` this over its standard streams and then exec, and the whole point is
/// that the streams survive.
pub fn openDevNull() Error!fd_t {
    const fd = open("/dev/null", O_RDWR);
    if (fd < 0) return error.OpenFailed;
    return fd;
}

const O_WRONLY: c_int = 1;
const O_CREAT: c_int = if (builtin.os.tag == .linux) 0o100 else 0x0200;
const O_APPEND: c_int = if (builtin.os.tag == .linux) 0o2000 else 0x0008;

/// Open `path` for appending, creating it 0600. Not close-on-exec, for the
/// same reason as `openDevNull`.
pub fn openAppend(path: [*:0]const u8) Error!fd_t {
    const fd = open(path, O_WRONLY | O_CREAT | O_APPEND, @as(c_uint, 0o600));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

/// Path to this executable, written into `buf`.
///
/// `std.fs.selfExePath` went away in Zig 0.16, and the stdio bridge needs it:
/// starting the host's daemon means starting *this* binary again. Resolving it
/// by name through `PATH` instead would be a different question with a
/// different answer, since the SSH command that started us was resolved
/// against a login shell's `PATH` and the daemon it starts outlives that shell.
pub fn selfExePath(buf: []u8) Error![]const u8 {
    if (builtin.os.tag.isDarwin()) {
        // On success the path is NUL-terminated and `size` is left alone; on
        // failure it is set to the length required, which is a bigger buffer
        // than `std.fs.max_path_bytes` and so not worth retrying for.
        var size: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
        if (_NSGetExecutablePath(buf.ptr, &size) != 0) return error.NoSelfExe;
        return std.mem.sliceTo(buf, 0);
    }
    const n = readlink("/proc/self/exe", buf.ptr, buf.len);
    if (n <= 0) return error.NoSelfExe;
    const len: usize = @intCast(n);
    // `readlink` does not terminate, and it truncates silently rather than
    // failing -- a path that exactly filled the buffer may have been cut.
    if (len >= buf.len) return error.NoSelfExe;
    return buf[0..len];
}

// -- unix sockets ----------------------------------------------------------

pub const SockAddrUn = std.c.sockaddr.un;

pub fn unixAddr(path: []const u8) Error!SockAddrUn {
    var addr: SockAddrUn = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

pub fn unixSocket() Error!fd_t {
    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    setCloexec(fd);
    return fd;
}

pub fn bindUnix(fd: fd_t, addr: *const SockAddrUn) Error!void {
    if (bind(fd, @ptrCast(addr), @sizeOf(SockAddrUn)) < 0) return error.BindFailed;
}

pub fn listenFd(fd: fd_t, backlog: u31) Error!void {
    if (listen(fd, backlog) < 0) return error.ListenFailed;
}

pub fn acceptFd(fd: fd_t) Error!fd_t {
    while (true) {
        const client = accept(fd, null, null);
        if (client >= 0) {
            setCloexec(client);
            return client;
        }
        if (errno() == EINTR) continue;
        return error.AcceptFailed;
    }
}

pub fn connectUnix(path: []const u8) Error!fd_t {
    const addr = try unixAddr(path);
    const fd = try unixSocket();
    errdefer closeFd(fd);
    if (connect(fd, @ptrCast(&addr), @sizeOf(SockAddrUn)) < 0) return error.ConnectFailed;
    return fd;
}

pub fn unlinkPath(path: [*:0]const u8) void {
    _ = unlink(path);
}

/// Both directions, for `shutdownFd`.
const SHUT_RDWR: c_int = 2;

/// Break both directions of a socket without closing the descriptor.
///
/// This is how a thread blocked in `read()` on a socket is woken so it can be
/// joined. `close` is not: on macOS it does not return while another thread
/// holds the same descriptor inside a blocking syscall, so joining after a bare
/// `close` deadlocks the two against each other -- the shape of issue #28, on
/// the PTY side. `shutdown` makes the pending read return zero and every later
/// write fail, and leaves the descriptor valid until its owner closes it.
pub fn shutdownFd(fd: fd_t) void {
    _ = shutdown(fd, SHUT_RDWR);
}

// -- time ------------------------------------------------------------------

const CLOCK_MONOTONIC: c_int = if (builtin.os.tag == .linux) 1 else 6;

extern "c" fn clock_gettime(clk: c_int, tp: *std.c.timespec) c_int;
extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

/// Sleep for `ns` nanoseconds. `std.Thread.sleep` is gone in Zig 0.16.
pub fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    while (nanosleep(&req, &req) != 0) {
        if (errno() != 4) break;
    }
}

/// Monotonic nanoseconds. Used for the PTY-read idle clock that drives parking,
/// so it must never go backwards.
pub fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

// -- processes -------------------------------------------------------------

pub fn forkProcess() Error!pid_t {
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    return pid;
}

pub fn exec(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) void {
    _ = execvp(file, argv);
}

pub const PipedChild = struct {
    pid: pid_t,
    /// Write here to reach the child's stdin.
    stdin: fd_t,
    /// Read here for the child's stdout.
    stdout: fd_t,
};

/// Run `argv` with pipes on its standard input and output.
///
/// Used for exactly one thing: `ssh <dest> illogicald --stdio`, where the two
/// pipes carry the wire protocol. The child keeps *our* stderr, so ssh's own
/// diagnostics -- a bad host key, a missing binary -- reach a person instead of
/// being decoded as frames.
///
/// `pipeFds` marks both ends close-on-exec, so the four originals do not
/// survive the exec. The two the child keeps are cleared explicitly below --
/// `dup2` clears the flag on the descriptor it *creates*, but `dup2(fd, fd)` is
/// a no-op and clears nothing, which is reachable whenever the caller was
/// started without a standard stream and `pipe` handed back fd 0 or 1.
pub fn spawnPiped(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) Error!PipedChild {
    const to_child = try pipeFds();
    errdefer {
        closeFd(to_child[0]);
        closeFd(to_child[1]);
    }
    const from_child = try pipeFds();
    errdefer {
        closeFd(from_child[0]);
        closeFd(from_child[1]);
    }

    const pid = try forkProcess();
    if (pid == 0) {
        // Child. Nothing here may allocate or return.
        dup2Fd(to_child[0], STDIN);
        dup2Fd(from_child[1], STDOUT);
        // Unconditional, and load-bearing when `dup2` above was a no-op: run
        // `illogical --host …` with stdin closed and `pipe` hands back fd 0,
        // so the child would exec with its stdin closed-on-exec and fail with
        // "Bad file descriptor" -- reported as the *remote* being unreachable.
        clearCloexec(STDIN);
        clearCloexec(STDOUT);
        exec(file, argv);
        exitProcess(127);
    }

    closeFd(to_child[0]);
    closeFd(from_child[1]);
    return .{ .pid = pid, .stdin = to_child[1], .stdout = from_child[0] };
}

pub fn exitProcess(code: u8) noreturn {
    _exit(code);
}

pub fn dup2Fd(old: fd_t, new: fd_t) void {
    _ = dup2(old, new);
}

pub fn chdirPath(path: [*:0]const u8) void {
    _ = chdir(path);
}

pub fn newSession() bool {
    return setsid() >= 0;
}

pub const SIGHUP: c_int = 1;
pub const SIGTERM: c_int = 15;
pub const SIGKILL: c_int = 9;

pub fn signal(pid: pid_t, sig: c_int) void {
    _ = kill(pid, sig);
}

/// Signal a whole process group. The child is a session leader (we call
/// `setsid` before exec), so this reaches the jobs it started too -- which is
/// what closing a terminal window does.
pub fn signalGroup(leader: pid_t, sig: c_int) void {
    _ = kill(-leader, sig);
}

/// Wait for `pid` and return its exit code. Blocks.
pub fn wait(pid: pid_t) i32 {
    var status: c_int = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno() != EINTR) return 0;
    }
    return exitCode(status);
}

const WNOHANG: c_int = 1;

pub const WaitResult = union(enum) {
    /// The child is still running.
    running,
    exited: i32,
    /// No such child: already reaped, or never ours to reap.
    gone,
};

/// Ask after `pid` without blocking.
///
/// The shared poller uses this. A child whose PTY hung up has almost always
/// exited, but `waitpid` would block if it has not, and the poller thread is
/// shared by every parked terminal on the machine -- one stuck child must not
/// stop the rest from being watched.
pub fn tryWait(pid: pid_t) WaitResult {
    var status: c_int = 0;
    while (true) {
        const got = waitpid(pid, &status, WNOHANG);
        if (got == 0) return .running;
        if (got > 0) return .{ .exited = exitCode(status) };
        if (errno() == EINTR) continue;
        return .gone;
    }
}

fn exitCode(status: c_int) i32 {
    // WIFEXITED / WEXITSTATUS
    if (status & 0x7f == 0) return @intCast((status >> 8) & 0xff);
    // Killed by a signal: report it the way a shell does.
    return 128 + @as(i32, @intCast(status & 0x7f));
}

// -- interrupting a blocked thread -----------------------------------------

/// The signal used to make a thread's blocking `read()` return.
///
/// `SIGUSR2` rather than `SIGUSR1`, which profilers and debuggers are likelier
/// to want for themselves. The handler does nothing at all: its only job is to
/// exist, so that delivery makes the blocked syscall fail with `EINTR` instead
/// of killing the process, which is what the default disposition would do.
pub const interrupt_signal = std.posix.SIG.USR2;

var interrupt_mutex: thread.Mutex = .{};
var interrupt_installed: bool = false;

/// Install the interrupt handler. Idempotent, and safe to call from anywhere.
///
/// Must happen before the first `interruptThread`, or the signal terminates
/// the daemon. Process-wide, which is worth knowing if this code is ever
/// embedded in something with its own opinion about `SIGUSR2`.
pub fn installThreadInterrupt() void {
    interrupt_mutex.lock();
    defer interrupt_mutex.unlock();
    if (interrupt_installed) return;

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onInterrupt },
        .mask = std.posix.sigemptyset(),
        // Deliberately not `SA_RESTART`. Restarting the syscall is the one
        // behaviour this must not have: the read has to come back so its
        // thread can notice why it was woken.
        .flags = 0,
    };
    std.posix.sigaction(interrupt_signal, &action, null);
    interrupt_installed = true;
}

fn onInterrupt(_: std.c.SIG) callconv(.c) void {}

/// Interrupt whatever blocking call `handle` is in.
///
/// The handle must not have been joined yet; a joinable thread's handle stays
/// valid until it is, even after the thread has returned.
pub fn interruptThread(handle: std.Thread.Handle) void {
    _ = std.c.pthread_kill(handle, interrupt_signal);
}

/// Set an environment variable for the current process. Used in the forked
/// child between `fork` and `exec`, where allocation is not allowed.
pub fn setenvVar(name: [*:0]const u8, value: [*:0]const u8) void {
    _ = setenv(name, value, 1);
}

pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

test "monotonic clock advances" {
    const a = monotonicNs();
    var spin: u64 = 0;
    while (spin < 100_000) : (spin += 1) std.mem.doNotOptimizeAway(spin);
    const b = monotonicNs();
    try std.testing.expect(b >= a);
}

test "this process can say where its own executable is" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try selfExePath(&buf);
    try testing.expect(path.len > 0);
    // The stdio bridge execs this, so a name is not enough: it has to be a
    // path that resolves without a `PATH` search, and it has to be there.
    try testing.expectEqual(@as(u8, '/'), path[0]);
    try std.Io.Dir.cwd().access(threaded.io(), path, .{});
}

test "unix address rejects an over-long path" {
    const testing = std.testing;
    const long = "x" ** 200;
    try testing.expectError(error.NameTooLong, unixAddr(long));
    const ok = try unixAddr("/tmp/illogical.sock");
    try testing.expectEqualStrings("/tmp/illogical.sock", std.mem.sliceTo(&ok.path, 0));
}

test "socketpair round trip over a unix socket" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/tmp/illogical-test-{d}.sock", .{std.c.getpid()});
    defer unlinkPath(path.ptr);

    const addr = try unixAddr(path);
    const server = try unixSocket();
    defer closeFd(server);
    try bindUnix(server, &addr);
    try listenFd(server, 1);

    const client = try connectUnix(path);
    defer closeFd(client);
    const accepted = try acceptFd(server);
    defer closeFd(accepted);

    try writeAll(client, "hello");
    var got: [5]u8 = undefined;
    try readAll(accepted, &got);
    try testing.expectEqualStrings("hello", &got);
}
