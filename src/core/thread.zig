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
