//! Threading primitives.
//!
//! Zig 0.16 removed `std.Thread.Mutex`, and `std.Io.Mutex` requires threading an
//! `Io` through every lock site. The daemon is a plain threaded server that
//! already links libc, so a pthread mutex is both simpler and exactly the right
//! primitive: statically initializable, no allocation, no `Io`.

const std = @import("std");

pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.inner) == .SUCCESS);
    }

    pub fn unlock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.inner) == .SUCCESS);
    }

    pub fn tryLock(self: *Mutex) bool {
        return std.c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
    }
};

/// A condition variable, paired with `Mutex`.
///
/// `std.Thread.Condition` went the same way as `std.Thread.Mutex` in Zig 0.16,
/// so this is the pthread primitive for the same reasons as above.
///
/// There is deliberately no `deinit`: the zero value is
/// `PTHREAD_COND_INITIALIZER`, and a statically initialized condition variable
/// holds no resources to release on either platform we build for.
pub const Condition = struct {
    inner: std.c.pthread_cond_t = .{},

    /// Atomically release `mutex` and block until signalled, then retake it.
    ///
    /// POSIX permits spurious wakeups, so every caller must re-test its
    /// predicate in a loop rather than assume a wakeup means progress.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        std.debug.assert(std.c.pthread_cond_wait(&self.inner, &mutex.inner) == .SUCCESS);
    }

    /// Wake one waiter.
    pub fn signal(self: *Condition) void {
        std.debug.assert(std.c.pthread_cond_signal(&self.inner) == .SUCCESS);
    }

    /// Wake every waiter, for when the predicate can now be true for more than
    /// one of them.
    pub fn broadcast(self: *Condition) void {
        std.debug.assert(std.c.pthread_cond_broadcast(&self.inner) == .SUCCESS);
    }
};

test "mutex locks and unlocks" {
    var m: Mutex = .{};
    m.lock();
    m.unlock();
    try std.testing.expect(m.tryLock());
    m.unlock();
}

test "mutex serializes threads" {
    const Ctx = struct {
        mutex: Mutex = .{},
        counter: u64 = 0,

        fn bump(self: *@This()) void {
            for (0..10_000) |_| {
                self.mutex.lock();
                self.counter += 1;
                self.mutex.unlock();
            }
        }
    };

    var ctx: Ctx = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Ctx.bump, .{&ctx});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, 40_000), ctx.counter);
}

test "a condition wakes a waiter" {
    const Ctx = struct {
        mutex: Mutex = .{},
        ready: Condition = .{},
        handed_over: bool = false,

        fn produce(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.handed_over = true;
            self.ready.signal();
        }
    };

    var ctx: Ctx = .{};
    const t = try std.Thread.spawn(.{}, Ctx.produce, .{&ctx});
    defer t.join();

    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    // The loop is not decoration: a spurious wakeup here would otherwise read
    // `handed_over` before the producer ever set it.
    while (!ctx.handed_over) ctx.ready.wait(&ctx.mutex);
    try std.testing.expect(ctx.handed_over);
}
