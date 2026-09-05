//! illogical core — the pieces shared by the daemon, the CLI, and (via the
//! generated headers) the native clients.

pub const protocol = @import("protocol.zig");
pub const session = @import("session.zig");
pub const park = @import("park.zig");
pub const pty = @import("pty.zig");

pub const version = "0.0.0-dev";

test {
    _ = protocol;
    _ = session;
    _ = park;
    _ = pty;
}
