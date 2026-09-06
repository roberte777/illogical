//! illogical core — the pieces shared by the daemon, the CLI, and (via the
//! generated headers) the native clients.

pub const protocol = @import("protocol.zig");
pub const session = @import("session.zig");
pub const crypt = @import("crypt.zig");
pub const park = @import("park.zig");
pub const poller = @import("poller.zig");
pub const pty = @import("pty.zig");
pub const conn = @import("conn.zig");
pub const sys = @import("sys.zig");
pub const thread = @import("thread.zig");

pub const version = "0.0.0-dev";

test {
    _ = protocol;
    _ = session;
    _ = crypt;
    _ = park;
    _ = poller;
    _ = pty;
    _ = conn;
    _ = sys;
    _ = thread;
}
