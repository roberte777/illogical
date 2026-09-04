//! PTY allocation and child spawning.
//!
//! Deliberately thin: the daemon owns the master fd and hands it to the event
//! loop. Nothing here interprets the byte stream — that is libghostty-vt's job.

const std = @import("std");
const posix = std.posix;

pub const WinSize = struct {
    cols: u16,
    rows: u16,
    /// Pixel dimensions, forwarded so that programs using the terminal's
    /// graphics protocols size themselves correctly.
    width_px: u16 = 0,
    height_px: u16 = 0,

    pub fn toPosix(self: WinSize) posix.winsize {
        return .{
            .col = self.cols,
            .row = self.rows,
            .xpixel = self.width_px,
            .ypixel = self.height_px,
        };
    }
};

/// A session's master side of the PTY pair.
pub const Pty = struct {
    master: posix.fd_t,
    slave: posix.fd_t,

    // TODO(scaffold): openpty/forkpty via posix_openpt + grantpt + unlockpt,
    // then spawn the child with the slave as its controlling terminal. Wire the
    // master fd into the libxev loop so readability both delivers output and
    // unparks the session.
};

/// Environment every session's child inherits, on top of the daemon's own.
pub const base_env = [_][2][]const u8{
    .{ "TERM", "xterm-ghostty" },
    .{ "TERM_PROGRAM", "illogical" },
    .{ "COLORTERM", "truecolor" },
};

test "winsize maps onto posix winsize" {
    const testing = std.testing;
    const ws: WinSize = .{ .cols = 120, .rows = 40 };
    const p = ws.toPosix();
    try testing.expectEqual(@as(u16, 120), p.col);
    try testing.expectEqual(@as(u16, 40), p.row);
}
