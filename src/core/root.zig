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

const build_options = @import("build_options");

/// What `--version` prints, and what the daemon puts in `welcome.server`.
///
/// Two parts, both stamped at build time by `build.zig`: the release version,
/// and the `vendor/ghostty` revision the binary was built against. The pin is
/// not decoration -- it is what decides whether this build and another agree
/// about a snapshot, since format v1 makes no promise across pins. A client
/// comparing its own bundled daemon against the one it is talking to has to
/// see two builds that differ only in pin as different.
///
/// Unstamped this reads `0.0.0-dev+gunknown`, which is honest: nobody told the
/// build what it was building.
pub const version = build_options.version ++ "+g" ++ build_options.ghostty_pin;

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
