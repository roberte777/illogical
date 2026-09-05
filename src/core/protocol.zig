//! The illogical wire protocol.
//!
//! One connection multiplexes every session the client cares about. Frames are
//! length-prefixed and carry a session id so that output for many sessions can
//! be interleaved on a single socket:
//!
//!     +--------+----------+--------+------------------+
//!     | type   | session  | len    | payload          |
//!     | u8     | u64 LE   | u32 LE | len bytes        |
//!     +--------+----------+--------+------------------+
//!
//! Session id 0 is reserved for connection-level control frames.
//!
//! The payload of `.output` is *unprocessed* PTY bytes: the server never
//! re-encodes what the program wrote. The payload of `.snapshot_chunk` is a
//! slice of libghostty-vt's `GHOSTSNP` stream, forwarded verbatim so the client
//! can feed it straight into `ghostty_snapshot_decoder_*`.
//!
//! See docs/PROTOCOL.md for the full message catalogue and the attach
//! handshake.

const std = @import("std");

/// Bumped on any incompatible change. The server refuses connections whose
/// `hello` advertises a different major version.
pub const version: u16 = 1;

/// Reserved session id for connection-level control frames.
pub const control_session: u64 = 0;

pub const header_len = 13;

/// Largest payload the server will accept in a single frame. Output is
/// chunked by the sender to stay under this.
pub const max_payload_len: u32 = 1 << 20;

pub const FrameType = enum(u8) {
    // ---- client -> server ------------------------------------------------
    /// Negotiate protocol version and announce client capabilities.
    hello = 0x01,
    /// Request the current session list.
    list = 0x02,
    /// Spawn a new session.
    create = 0x03,
    /// Subscribe to a session: triggers the snapshot + live-output handshake.
    attach = 0x04,
    /// Stop receiving output for a session without killing it.
    detach = 0x05,
    /// Terminate a session and discard its parked state.
    kill = 0x06,
    /// Raw bytes destined for the session's PTY.
    input = 0x07,
    /// Window size change for this client's view of a session.
    resize = 0x08,
    ping = 0x09,

    // ---- server -> client ------------------------------------------------
    welcome = 0x81,
    session_list = 0x82,
    created = 0x83,
    /// A snapshot stream for `session` follows. Payload carries the snapshot
    /// format version so the client can reject one it cannot decode.
    snapshot_begin = 0x84,
    /// Verbatim `GHOSTSNP` bytes. Feed directly to the libghostty-vt decoder.
    snapshot_chunk = 0x85,
    /// The decoder has everything through the snapshot's READY marker: the
    /// client can paint the current screen now. History pages keep arriving in
    /// later `snapshot_chunk` frames.
    snapshot_ready = 0x86,
    /// The snapshot's FINISH marker has been sent; scrollback is complete.
    snapshot_end = 0x87,
    /// Unprocessed PTY output.
    output = 0x88,
    /// The session's child process exited.
    exited = 0x89,
    /// The session list changed (created/killed/renamed elsewhere).
    sessions_changed = 0x8a,
    err = 0x8b,
    pong = 0x8c,

    pub fn isClientToServer(self: FrameType) bool {
        return @intFromEnum(self) < 0x80;
    }
};

pub const Header = struct {
    type: FrameType,
    session: u64,
    len: u32,

    pub fn encode(self: Header, out: *[header_len]u8) void {
        out[0] = @intFromEnum(self.type);
        std.mem.writeInt(u64, out[1..9], self.session, .little);
        std.mem.writeInt(u32, out[9..13], self.len, .little);
    }

    pub fn decode(buf: *const [header_len]u8) DecodeError!Header {
        const frame_type = std.enums.fromInt(FrameType, buf[0]) orelse
            return error.UnknownFrameType;
        const len = std.mem.readInt(u32, buf[9..13], .little);
        if (len > max_payload_len) return error.PayloadTooLarge;
        return .{
            .type = frame_type,
            .session = std.mem.readInt(u64, buf[1..9], .little),
            .len = len,
        };
    }
};

pub const DecodeError = error{
    UnknownFrameType,
    PayloadTooLarge,
};

/// Error codes carried by an `err` frame.
pub const ErrorCode = enum(u16) {
    unknown = 0,
    version_mismatch = 1,
    no_such_session = 2,
    session_busy = 3,
    spawn_failed = 4,
    unpark_failed = 5,
    malformed_frame = 6,
    _,
};

test "header round trip" {
    const testing = std.testing;
    var buf: [header_len]u8 = undefined;
    const want: Header = .{ .type = .output, .session = 0xdead_beef_cafe, .len = 4096 };
    want.encode(&buf);
    const got = try Header.decode(&buf);
    try testing.expectEqual(want.type, got.type);
    try testing.expectEqual(want.session, got.session);
    try testing.expectEqual(want.len, got.len);
}

test "header rejects oversized payloads" {
    const testing = std.testing;
    var buf: [header_len]u8 = undefined;
    const h: Header = .{ .type = .output, .session = 1, .len = max_payload_len + 1 };
    h.encode(&buf);
    try testing.expectError(error.PayloadTooLarge, Header.decode(&buf));
}

test "header rejects unknown frame types" {
    const testing = std.testing;
    var buf: [header_len]u8 = @splat(0);
    buf[0] = 0x7f;
    try testing.expectError(error.UnknownFrameType, Header.decode(&buf));
}

test "frame direction" {
    const testing = std.testing;
    try testing.expect(FrameType.input.isClientToServer());
    try testing.expect(!FrameType.output.isClientToServer());
}
