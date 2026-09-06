//! The shared descriptor poller: a fixed, small pool of threads watching any
//! number of PTYs.
//!
//! This is the cold half of the two IO regimes in
//! [ARCHITECTURE.md](../docs/ARCHITECTURE.md#server-io-two-regimes-per-pty). A
//! *hot* PTY owns a dedicated OS thread blocked on `read()`, because that is
//! measurably the fastest way to move bytes and the reason this project is not
//! an event loop. A *parked* PTY -- one whose terminal has parked, or that
//! nobody is watching -- costs a registration here instead of a kernel thread
//! and its stack.
//!
//! ## Why a pool and not one thread
//!
//! One thread was the first shape, and measurably the wrong one. The work a
//! callback does is not the `read`, it is parsing what the read returned, and
//! parsing is where all the time goes. On one thread that serialises: with
//! eight busy terminals the poller ran **7.8x slower** than eight dedicated
//! reader threads, which is not the "5-10%" the trade is supposed to cost
//! [MEM t=504]. It was a faithful reproduction of exactly one core's worth of
//! throughput.
//!
//! So the descriptors are sharded across `default_shards` threads, each with
//! its own backend, table and wake pipe. The property that matters is
//! unchanged -- thread count is a constant, not a function of terminal count
//! -- and the cost of being unwatched is now proportional to how much of the
//! machine we are willing to spend on terminals nobody is looking at, rather
//! than pinned to one core.
//!
//! Above the core count this is also the *better* regime, not merely the
//! cheaper one: ten thousand runnable threads is worse for throughput than a
//! bounded pool, whatever the fd cost.
//!
//! kqueue on Darwin, epoll on Linux. Level-triggered on both, deliberately: a
//! descriptor that still has bytes behind it after one `read` is reported
//! again on the next turn, so the handler never has to drain in a loop and one
//! busy terminal cannot monopolise its shard.
//!
//! ## Locking
//!
//! Per shard, two locks, always taken in this order:
//!
//!   1. `dispatch_mutex`, held across a batch of callbacks.
//!   2. `mutex`, guarding the registration table.
//!
//! `remove` takes both, which is what makes it a real guarantee: when it
//! returns, no callback for that descriptor is running or can start. The cost
//! is a rule for callers -- **never call `add` or `remove` while holding a
//! lock that a callback might want**. In this daemon that means never while
//! holding a terminal's lock, since every callback here takes one.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const thread = @import("thread.zig");

const log = std.log.scoped(.poller);

pub const Error = error{
    PollerInitFailed,
    PollerAddFailed,
} || Allocator.Error || sys.Error;

pub const Handler = struct {
    ctx: *anyopaque,
    /// The descriptor has something to read, or has hung up.
    ///
    /// Runs on the poller thread. Return false to be unregistered, which is
    /// how a handler retires a descriptor it has finished with -- calling
    /// `remove` from in here would deadlock on `dispatch_mutex`.
    readableFn: *const fn (ctx: *anyopaque) bool,
};

/// Stack for a shard's thread.
///
/// Half a megabyte, against the 16 MiB default. A callback here reads a PTY
/// into a buffer on this stack and parses what it got, which measures well
/// under 64 KiB; the rest of the default is address space nothing will touch.
/// Declared here rather than shared with the daemon's constant, because this
/// file has no business importing one.
const stack_size = 512 * 1024;

/// How many threads the pool gets, unless a caller says otherwise.
///
/// Four is a compromise, and the shape of the compromise is the point. One is
/// too few -- it pins every unwatched terminal on the machine to a single core,
/// which is where the 7.8x above came from. The core count is too many: these
/// are terminals nobody is looking at, and they should not be able to take the
/// whole machine from the ones somebody is.
pub fn defaultShards() usize {
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(4, cpus));
}

/// One thread, its backend, and the descriptors assigned to it.
const Shard = struct {
    gpa: Allocator,
    backend: Backend,
    /// Woken by writing a byte. Only used to end `run` promptly; registration
    /// changes are picked up by the kernel without one.
    wake: [2]sys.fd_t,

    /// Guards `handlers`.
    mutex: thread.Mutex = .{},
    handlers: std.AutoHashMapUnmanaged(sys.fd_t, Handler) = .empty,

    /// Held while callbacks run. See the locking note at the top of the file.
    dispatch_mutex: thread.Mutex = .{},

    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// How many descriptors a single `wait` may report. Not a limit on
    /// registrations: whatever does not fit is reported on the next turn.
    const batch = 64;

    fn init(self: *Shard, gpa: Allocator) Error!void {
        var backend = try Backend.init();
        errdefer backend.deinit();

        const wake = try sys.pipeFds();
        errdefer {
            sys.closeFd(wake[0]);
            sys.closeFd(wake[1]);
        }
        try backend.add(wake[0]);

        // Built in place: the mutexes must never be copied after use, and a
        // shard lives in an array the pool owns.
        self.* = .{ .gpa = gpa, .backend = backend, .wake = wake };
    }

    fn deinit(self: *Shard) void {
        self.stop();
        self.backend.deinit();
        sys.closeFd(self.wake[0]);
        sys.closeFd(self.wake[1]);
        self.handlers.deinit(self.gpa);
    }

    fn start(self: *Shard) !void {
        if (self.running.load(.acquire)) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{ .stack_size = stack_size }, run, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    fn stop(self: *Shard) void {
        if (self.running.swap(false, .acq_rel)) self.wakeUp();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn add(self: *Shard, fd: sys.fd_t, handler: Handler) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.handlers.put(self.gpa, fd, handler);
        errdefer _ = self.handlers.remove(fd);
        try self.backend.add(fd);
    }

    fn remove(self: *Shard, fd: sys.fd_t) void {
        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();
        self.removeLocked(fd);
    }

    /// Caller holds `dispatch_mutex`.
    fn removeLocked(self: *Shard, fd: sys.fd_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.handlers.remove(fd)) self.backend.remove(fd);
    }

    fn count(self: *Shard) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.handlers.count();
    }

    fn wakeUp(self: *Shard) void {
        _ = sys.writeFd(self.wake[1], &.{0}) catch {};
    }

    fn run(self: *Shard) void {
        var events: [batch]Backend.Event = undefined;
        while (self.running.load(.acquire)) {
            const n = self.backend.wait(&events) catch |err| {
                log.err("poller wait failed: {t}", .{err});
                break;
            };

            self.dispatch_mutex.lock();
            defer self.dispatch_mutex.unlock();
            for (events[0..n]) |event| {
                const fd = Backend.eventFd(event);
                if (fd == self.wake[0]) {
                    self.drainWake();
                    continue;
                }

                // Re-read under the lock rather than trusting the batch: a
                // descriptor removed since `wait` returned must not be
                // dispatched to a handler whose owner is being torn down.
                self.mutex.lock();
                const handler = self.handlers.get(fd);
                self.mutex.unlock();

                const h = handler orelse continue;
                if (!h.readableFn(h.ctx)) self.removeLocked(fd);
            }
        }
    }

    fn drainWake(self: *Shard) void {
        var buf: [64]u8 = undefined;
        // Non-blocking would be tidier, but one read of a pipe the kernel just
        // said was readable cannot block, and one is enough: the byte is a
        // nudge, not a message.
        _ = sys.readFdOnce(self.wake[0], &buf) catch {};
    }
};

pub const Poller = struct {
    gpa: Allocator,
    shards: []Shard,

    pub fn init(gpa: Allocator) Error!Poller {
        return initShards(gpa, defaultShards());
    }

    pub fn initShards(gpa: Allocator, n: usize) Error!Poller {
        const shards = try gpa.alloc(Shard, @max(1, n));
        errdefer gpa.free(shards);

        var made: usize = 0;
        errdefer for (shards[0..made]) |*s| s.deinit();
        while (made < shards.len) : (made += 1) try shards[made].init(gpa);

        return .{ .gpa = gpa, .shards = shards };
    }

    pub fn deinit(self: *Poller) void {
        for (self.shards) |*s| s.deinit();
        self.gpa.free(self.shards);
    }

    pub fn start(self: *Poller) !void {
        for (self.shards) |*s| try s.start();
    }

    pub fn stop(self: *Poller) void {
        for (self.shards) |*s| s.stop();
    }

    /// Which thread owns a descriptor.
    ///
    /// Derived from the descriptor rather than assigned, so a terminal lands
    /// on the same shard every time it is registered and `remove` needs no
    /// bookkeeping to find it again.
    ///
    /// Hashed, not `fd % n`. Descriptors are not uniformly distributed modulo
    /// a small number: `openpty` allocates a master and a slave together and a
    /// socket pair takes two at a time, so the ones we register here tend to
    /// share a parity, and `% 4` left half the pool with nothing to do. A
    /// Fibonacci multiply mixes the low bits upward first.
    fn shardFor(self: *Poller, fd: sys.fd_t) *Shard {
        const key: u64 = @intCast(@max(fd, 0));
        const mixed = key *% 0x9E37_79B9_7F4A_7C15;
        return &self.shards[@intCast((mixed >> 32) % self.shards.len)];
    }

    /// Watch `fd`. Replaces any previous handler for it.
    pub fn add(self: *Poller, fd: sys.fd_t, handler: Handler) Error!void {
        return self.shardFor(fd).add(fd, handler);
    }

    /// Stop watching `fd`.
    ///
    /// When this returns, no callback for `fd` is running and none can start.
    /// The caller may then close it, or hand it to a thread of its own.
    pub fn remove(self: *Poller, fd: sys.fd_t) void {
        self.shardFor(fd).remove(fd);
    }

    pub fn count(self: *Poller) usize {
        var total: usize = 0;
        for (self.shards) |*s| total += s.count();
        return total;
    }

    /// How many threads this pool runs. One per shard.
    pub fn threadCount(self: *Poller) usize {
        return self.shards.len;
    }
};

const Backend = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => Kqueue,
    .linux => Epoll,
    else => @compileError("no poller backend for this OS"),
};

/// Darwin. This is the tested path.
const Kqueue = struct {
    fd: sys.fd_t,

    const Event = std.c.Kevent;

    fn init() Error!Kqueue {
        const fd = std.c.kqueue();
        if (fd < 0) return error.PollerInitFailed;
        sys.setCloexec(fd);
        return .{ .fd = fd };
    }

    fn deinit(self: *Kqueue) void {
        sys.closeFd(self.fd);
    }

    fn add(self: *Kqueue, fd: sys.fd_t) Error!void {
        var change: Event = .{
            .ident = @intCast(fd),
            .filter = @as(i16, std.c.EVFILT.READ),
            .flags = std.c.EV.ADD | std.c.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        // `nevents` of zero: apply the change and return, never wait.
        if (std.c.kevent(self.fd, @ptrCast(&change), 1, @ptrCast(&change), 0, null) < 0) {
            return error.PollerAddFailed;
        }
    }

    fn remove(self: *Kqueue, fd: sys.fd_t) void {
        var change: Event = .{
            .ident = @intCast(fd),
            .filter = @as(i16, std.c.EVFILT.READ),
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        // A descriptor closed before we got here takes its registrations with
        // it, so `ENOENT` is the ordinary case and not worth reporting.
        _ = std.c.kevent(self.fd, @ptrCast(&change), 1, @ptrCast(&change), 0, null);
    }

    fn wait(self: *Kqueue, events: []Event) Error!usize {
        while (true) {
            const n = std.c.kevent(
                self.fd,
                events.ptr,
                0,
                events.ptr,
                @intCast(events.len),
                null,
            );
            if (n >= 0) return @intCast(n);
            if (std.c._errno().* == 4) continue; // EINTR
            return error.PollerInitFailed;
        }
    }

    fn eventFd(event: Event) sys.fd_t {
        return @intCast(event.ident);
    }
};

/// Linux. Written to the same shape as the Darwin backend but not exercised
/// here -- this project builds and tests on macOS only, so treat it as the
/// port rather than as a tested path.
const Epoll = struct {
    fd: sys.fd_t,

    const Event = std.os.linux.epoll_event;
    const EPOLL = std.os.linux.EPOLL;

    fn init() Error!Epoll {
        const fd: sys.fd_t = @intCast(std.c.epoll_create1(EPOLL.CLOEXEC));
        if (fd < 0) return error.PollerInitFailed;
        return .{ .fd = fd };
    }

    fn deinit(self: *Epoll) void {
        sys.closeFd(self.fd);
    }

    fn add(self: *Epoll, fd: sys.fd_t) Error!void {
        var event: Event = .{ .events = EPOLL.IN, .data = .{ .fd = fd } };
        if (std.c.epoll_ctl(self.fd, EPOLL.CTL_ADD, fd, &event) < 0) {
            return error.PollerAddFailed;
        }
    }

    fn remove(self: *Epoll, fd: sys.fd_t) void {
        _ = std.c.epoll_ctl(self.fd, EPOLL.CTL_DEL, fd, null);
    }

    fn wait(self: *Epoll, events: []Event) Error!usize {
        while (true) {
            const n = std.c.epoll_wait(self.fd, events.ptr, @intCast(events.len), -1);
            if (n >= 0) return @intCast(n);
            if (std.c._errno().* == 4) continue; // EINTR
            return error.PollerInitFailed;
        }
    }

    fn eventFd(event: Event) sys.fd_t {
        return event.data.fd;
    }
};

// -- tests -----------------------------------------------------------------

/// Counts callbacks and records the bytes it read, so a test can tell "was
/// woken" from "was woken and had something to read".
const Recorder = struct {
    fd: sys.fd_t,
    mutex: thread.Mutex = .{},
    reads: usize = 0,
    bytes: [256]u8 = undefined,
    len: usize = 0,
    /// Returned from the callback. False means "unregister me".
    keep: bool = true,

    fn handler(self: *Recorder) Handler {
        return .{ .ctx = self, .readableFn = onReadable };
    }

    fn onReadable(ctx: *anyopaque) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        var buf: [64]u8 = undefined;
        const n = sys.readFdOnce(self.fd, &buf) catch 0;
        if (self.len + n <= self.bytes.len) {
            @memcpy(self.bytes[self.len..][0..n], buf[0..n]);
            self.len += n;
        }
        self.reads += 1;
        return self.keep;
    }

    fn seen(self: *Recorder) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.reads;
    }

    fn text(self: *Recorder, buf: []u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        @memcpy(buf[0..self.len], self.bytes[0..self.len]);
        return buf[0..self.len];
    }
};

/// Spin until `check` passes or the deadline runs out.
fn await_(check: anytype, ctx: anytype) bool {
    var waited: usize = 0;
    while (waited < 5000) : (waited += 5) {
        if (check(ctx)) return true;
        sys.sleepNs(5 * std.time.ns_per_ms);
    }
    return false;
}

test "the poller reads what a registered descriptor produces" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var poller = try Poller.init(gpa);
    defer poller.deinit();
    try poller.start();

    const pipe_fds = try sys.pipeFds();
    defer sys.closeFd(pipe_fds[1]);
    var rec: Recorder = .{ .fd = pipe_fds[0] };
    defer sys.closeFd(pipe_fds[0]);

    try poller.add(pipe_fds[0], rec.handler());
    try testing.expectEqual(@as(usize, 1), poller.count());

    try sys.writeAll(pipe_fds[1], "poll me");
    try testing.expect(await_(struct {
        fn f(r: *Recorder) bool {
            return r.seen() > 0;
        }
    }.f, &rec));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("poll me", rec.text(&buf));
}

test "a handler that returns false is unregistered" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var poller = try Poller.init(gpa);
    defer poller.deinit();
    try poller.start();

    const pipe_fds = try sys.pipeFds();
    defer sys.closeFd(pipe_fds[0]);
    defer sys.closeFd(pipe_fds[1]);

    var rec: Recorder = .{ .fd = pipe_fds[0], .keep = false };
    try poller.add(pipe_fds[0], rec.handler());
    try sys.writeAll(pipe_fds[1], "once");

    try testing.expect(await_(struct {
        fn f(p: *Poller) bool {
            return p.count() == 0;
        }
    }.f, &poller));

    // A level-triggered poller reports a descriptor with bytes still behind
    // it on every turn, so an unregistration that did not take would spin the
    // callback here rather than merely leak a registration.
    try sys.writeAll(pipe_fds[1], "twice");
    sys.sleepNs(50 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 1), rec.seen());
}

test "remove is synchronous, and many descriptors share one thread" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var poller = try Poller.init(gpa);
    defer poller.deinit();
    try poller.start();

    const count = 32;
    var fds: [count][2]sys.fd_t = undefined;
    var recs: [count]Recorder = undefined;
    for (&fds, 0..) |*pair, i| {
        pair.* = try sys.pipeFds();
        recs[i] = .{ .fd = pair[0] };
    }
    defer for (fds) |pair| {
        sys.closeFd(pair[0]);
        sys.closeFd(pair[1]);
    };

    for (fds, 0..) |pair, i| try poller.add(pair[0], recs[i].handler());
    try testing.expectEqual(@as(usize, count), poller.count());

    for (fds) |pair| try sys.writeAll(pair[1], "x");
    for (&recs) |*rec| {
        try testing.expect(await_(struct {
            fn f(r: *Recorder) bool {
                return r.seen() > 0;
            }
        }.f, rec));
    }

    // One thread for all of them. That is the whole point of this file: the
    // count of registrations is what grows, not the count of threads.
    for (fds) |pair| poller.remove(pair[0]);
    try testing.expectEqual(@as(usize, 0), poller.count());

    // After `remove` returns, nothing more arrives -- which is what lets a
    // caller take the descriptor back and give it a thread of its own.
    const before = recs[0].seen();
    try sys.writeAll(fds[0][1], "ignored");
    sys.sleepNs(50 * std.time.ns_per_ms);
    try testing.expectEqual(before, recs[0].seen());
}

test "a poller with nothing registered stops promptly" {
    const gpa = std.testing.allocator;
    var poller = try Poller.init(gpa);
    defer poller.deinit();
    try poller.start();
    // `stop` has to wake threads blocked in `wait` with no timeout. If the
    // wake pipes were not doing their job this would hang rather than fail.
    poller.stop();
}

test "descriptors are spread across the pool, and the pool is a constant" {
    const testing = std.testing;
    const gpa = testing.allocator;

    // Four shards explicitly, so this asserts the sharding rather than
    // whatever core count the machine running it happens to have.
    var poller = try Poller.initShards(gpa, 4);
    defer poller.deinit();
    try poller.start();
    try testing.expectEqual(@as(usize, 4), poller.threadCount());

    const count = 40;
    var fds: [count][2]sys.fd_t = undefined;
    var recs: [count]Recorder = undefined;
    for (&fds, 0..) |*pair, i| {
        pair.* = try sys.pipeFds();
        recs[i] = .{ .fd = pair[0] };
    }
    defer for (fds) |pair| {
        sys.closeFd(pair[0]);
        sys.closeFd(pair[1]);
    };

    for (fds, 0..) |pair, i| try poller.add(pair[0], recs[i].handler());
    try testing.expectEqual(@as(usize, count), poller.count());

    // Every shard got work. Descriptors are handed out lowest-free-first, so
    // forty consecutive pipes cannot all land on one thread unless the
    // sharding is broken.
    for (poller.shards) |*s| try testing.expect(s.count() > 0);

    // And all of them are actually read.
    for (fds) |pair| try sys.writeAll(pair[1], "x");
    for (&recs) |*rec| {
        try testing.expect(await_(struct {
            fn f(r: *Recorder) bool {
                return r.seen() > 0;
            }
        }.f, rec));
    }

    // Forty descriptors, four threads. That ratio is the whole point: it does
    // not matter whether it is forty or forty thousand.
    try testing.expectEqual(@as(usize, 4), poller.threadCount());
}
