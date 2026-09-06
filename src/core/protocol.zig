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
    /// Ask for the server's rendered screen as plain text. Useful for scripts
    /// and agents that want to read a terminal without attaching to it.
    peek = 0x0a,

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
    /// Plain-text rendering of the terminal, in reply to `peek`.
    screen = 0x8d,

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
    /// The client fell far enough behind that the server dropped its bounded
    /// output queue rather than buffer without limit. Output after this frame
    /// is missing, and the server has already unsubscribed the client, so the
    /// only recovery is a fresh `attach` -- which is the same path as any
    /// other desync. See docs/PROTOCOL.md.
    desync = 7,
    _,
};

/// Control-frame bodies.
///
/// The hot path -- `output`, `input`, `snapshot_chunk` -- carries raw bytes with
/// no body encoding at all, which is the whole point (see docs/PROTOCOL.md C1).
/// Control frames are rare, so they use JSON: it costs nothing where it is used
/// and it keeps the two implementations of this protocol honest with each other.
pub const body = struct {
    pub const Hello = struct {
        version: u16 = version,
        client: []const u8 = "unknown",
    };

    pub const Welcome = struct {
        version: u16 = version,
        server: []const u8,
    };

    pub const Create = struct {
        session_name: []const u8 = "default",
        name: []const u8 = "",
        argv: []const []const u8 = &.{},
        cwd: ?[]const u8 = null,
        cols: u16 = 80,
        rows: u16 = 24,
    };

    pub const Created = struct {
        terminal: u64,
        session: u64,
    };

    pub const TerminalInfo = struct {
        id: u64,
        session: u64,
        name: []const u8,
        command: []const u8,
        cwd: []const u8,
        cols: u16,
        rows: u16,
        residency: []const u8,
        attached: u32,
        pty_read_idle_ns: u64,
        exit_code: ?i32 = null,
    };

    pub const SessionInfo = struct {
        id: u64,
        name: []const u8,
        terminals: []const u64,
    };

    pub const SessionList = struct {
        sessions: []const SessionInfo,
        terminals: []const TerminalInfo,
    };

    pub const Attach = struct {
        cols: u16 = 80,
        rows: u16 = 24,
    };

    pub const Resize = struct {
        cols: u16,
        rows: u16,
    };

    pub const Kill = struct {
        /// Zero means hang up (SIGHUP to the process group), which is what
        /// closing a tab means. SIGTERM would be ignored by an interactive
        /// shell, so it is deliberately not the default.
        signal: i32 = 0,
    };

    pub const Exited = struct {
        code: i32,
    };

    pub const Err = struct {
        code: u16,
        message: []const u8,
    };

    pub const SnapshotBegin = struct {
        format: u16 = 1,
    };

    pub const Peek = struct {
        /// Include scrollback, not just the active screen.
        scrollback: bool = false,
    };

    pub fn encode(alloc: std.mem.Allocator, value: anytype) ![]u8 {
        return std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(value, .{})});
    }

    pub fn decode(comptime T: type, alloc: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, alloc, bytes, .{ .allocate = .alloc_always });
    }
};

test "control bodies round trip through json" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const want: body.Create = .{
        .session_name = "work",
        .name = "build",
        .argv = &.{ "zsh", "-l" },
        .cols = 120,
        .rows = 40,
    };
    const bytes = try body.encode(alloc, want);
    defer alloc.free(bytes);

    const got = try body.decode(body.Create, alloc, bytes);
    defer got.deinit();
    try testing.expectEqualStrings("work", got.value.session_name);
    try testing.expectEqualStrings("build", got.value.name);
    try testing.expectEqual(@as(usize, 2), got.value.argv.len);
    try testing.expectEqual(@as(u16, 120), got.value.cols);
}

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
