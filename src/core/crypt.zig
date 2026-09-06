//! Encryption for park files.
//!
//! A parked terminal is its scrollback, and scrollback is where secrets end up
//! — a token echoed by mistake, a connection string in a stack trace, whatever
//! the last hour of work put on the screen. Mitchell says Superlogical encrypts
//! parked snapshots for exactly that reason and names no algorithm:
//!
//! > "there's encryption and other security involved there to prevent — there's
//! > often secrets in scrollback, so we have to protect against that."
//! > — [MEM t=278]
//!
//! So this is ours. XChaCha20-Poly1305, chunked, over the *compressed* stream:
//!
//!     "ILGPARK1" | nonce prefix (16B) | chunk | chunk | ... | terminator
//!
//!     chunk       = u32 LE length | ciphertext | tag (16B)
//!     terminator  = u32 LE 0      |            | tag (16B)
//!
//! Chunked because parking and unparking must stay streaming — the whole point
//! of the format is that a terminal becomes usable before the last byte has
//! been read, and a single AEAD over the file would mean buffering all of it to
//! verify one tag. Every chunk carries its own tag, so a corrupted one is
//! caught where it is read rather than after.
//!
//! ## What the construction defends against
//!
//! Each chunk's nonce is the file's random 16-byte prefix followed by the
//! chunk's index, so no two chunks in a file — and, with overwhelming
//! probability, no two chunks ever — share one. The index is in the nonce
//! rather than only the tag, which is what stops chunks being *reordered*: a
//! chunk moved to another position decrypts under a different nonce and fails.
//!
//! The terminator is what stops **truncation**. It is an empty chunk whose
//! associated data marks it final, so a file that stops early has no valid
//! final chunk and the decoder says so instead of handing back a shorter
//! scrollback that looks entirely plausible.
//!
//! ## What it does not defend against
//!
//! The key sits next to the data, in a file mode 0600 in the same directory.
//! Anyone who can read the park store as this user can read the key and
//! therefore the scrollback, and that is not a bug we can fix here — it is the
//! same trust boundary the socket already has. What it buys is everything that
//! *leaves* that boundary: backups, disk images, a stale state directory in a
//! container layer, a laptop handed on. Those stop being plaintext.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

pub const Key = [Aead.key_length]u8;
pub const tag_len = Aead.tag_length;

/// The random part of a nonce. The rest is the chunk index.
pub const nonce_prefix_len = Aead.nonce_length - @sizeOf(u64);

pub const magic = "ILGPARK1";
pub const header_len = magic.len + nonce_prefix_len;

/// Plaintext bytes per chunk.
///
/// The tag costs 16 bytes per chunk, so this trades overhead against how much
/// has to arrive before any of it can be used. At 32 KiB the overhead is 0.05%
/// and the streaming granularity is far finer than a snapshot's READY prefix,
/// which is the only latency anybody can see.
pub const chunk_len = 32 * 1024;

/// Associated data: one byte saying whether this is the last chunk.
const ad_data = [_]u8{0};
const ad_final = [_]u8{1};

pub const Error = error{
    /// Not a park file this build knows how to read.
    BadParkMagic,
    /// A chunk failed its authentication tag, or arrived out of order.
    ParkAuthFailed,
    /// A chunk header declared more than `chunk_len` bytes.
    ParkChunkTooLarge,
};

fn nonceFor(prefix: [nonce_prefix_len]u8, counter: u64) [Aead.nonce_length]u8 {
    var nonce: [Aead.nonce_length]u8 = undefined;
    @memcpy(nonce[0..nonce_prefix_len], &prefix);
    std.mem.writeInt(u64, nonce[nonce_prefix_len..][0..8], counter, .little);
    return nonce;
}

/// Encrypts everything written to `writer` and emits it to `out`.
///
/// Call `finish` when done: it flushes the partial chunk and writes the
/// terminator that makes truncation detectable. Dropping an `Encryptor`
/// without it leaves a file no `Decryptor` will accept, which is the correct
/// failure -- a park that died halfway through should not be readable.
pub const Encryptor = struct {
    out: *std.Io.Writer,
    key: Key,
    nonce_prefix: [nonce_prefix_len]u8,
    counter: u64 = 0,
    finished: bool = false,

    /// What callers write to.
    writer: std.Io.Writer,

    /// Plaintext waiting to fill a chunk. This *is* the writer's buffer, so
    /// small writes accumulate here for free and a large one is encrypted
    /// straight out of the caller's slice.
    pending: [chunk_len]u8 = undefined,
    /// One chunk's ciphertext, so `emit` needs no allocator.
    cipher: [chunk_len]u8 = undefined,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    /// Must be built in place: `writer` points back at this struct.
    ///
    /// Takes the nonce prefix rather than generating one, so that a test can
    /// pin it and `initRandom` is the only thing that has to be trusted to
    /// produce a fresh one.
    pub fn init(
        self: *Encryptor,
        out: *std.Io.Writer,
        key: Key,
        nonce_prefix: [nonce_prefix_len]u8,
    ) void {
        self.* = .{
            .out = out,
            .key = key,
            .nonce_prefix = nonce_prefix,
            .writer = undefined,
        };
        // After the struct is in place: the writer's buffer points into it.
        self.writer = .{ .vtable = &vtable, .buffer = &self.pending };
    }

    /// The real one. A fresh random prefix per file is what keeps a nonce from
    /// ever repeating across files under one key.
    pub fn initRandom(self: *Encryptor, io: std.Io, out: *std.Io.Writer, key: Key) !void {
        var prefix: [nonce_prefix_len]u8 = undefined;
        try io.randomSecure(&prefix);
        self.init(out, key, prefix);
    }

    /// Write the header. Separate from `init` so that a failure here is a
    /// normal error rather than something `init` has to report.
    pub fn writeHeader(self: *Encryptor) !void {
        try self.out.writeAll(magic);
        try self.out.writeAll(&self.nonce_prefix);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Encryptor = @fieldParentPtr("writer", w);

        // What the framework buffered comes first in the stream. Emitted
        // before `consumeAll` clears it, and before anything in `data`.
        self.emitAll(w.buffered()) catch return error.WriteFailed;
        _ = w.consumeAll();

        var written: usize = 0;
        for (data, 0..) |slice, i| {
            const times = if (i == data.len - 1) splat else 1;
            for (0..times) |_| {
                self.emitAll(slice) catch return error.WriteFailed;
                written += slice.len;
            }
        }
        return written;
    }

    /// Encrypt `bytes` as one or more whole chunks. Nothing is retained: the
    /// writer's own buffer is the only place partial data ever waits.
    fn emitAll(self: *Encryptor, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const take = @min(chunk_len, rest.len);
            try self.emit(rest[0..take], &ad_data);
            rest = rest[take..];
        }
    }

    fn emit(self: *Encryptor, plain: []const u8, ad: []const u8) !void {
        var tag: [tag_len]u8 = undefined;
        Aead.encrypt(
            self.cipher[0..plain.len],
            &tag,
            plain,
            ad,
            nonceFor(self.nonce_prefix, self.counter),
            self.key,
        );

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(plain.len), .little);
        try self.out.writeAll(&len_buf);
        if (plain.len > 0) try self.out.writeAll(self.cipher[0..plain.len]);
        try self.out.writeAll(&tag);
        self.counter += 1;
    }

    /// Flush the partial chunk and write the terminator.
    pub fn finish(self: *Encryptor) !void {
        if (self.finished) return;
        // The partial chunk goes out as data; the terminator is always its own
        // empty chunk. Simpler than marking the last data chunk final, and it
        // means a file that happens to end on a chunk boundary is not a
        // special case.
        try self.writer.flush();
        try self.emit(&.{}, &ad_final);
        self.finished = true;
    }
};

/// Decrypts a stream written by `Encryptor`.
///
/// `reader` is what callers read from. Every chunk is authenticated as it is
/// read, and the stream ends only at a valid terminator -- a file cut short
/// reports `ParkAuthFailed` rather than a short read that looks like a small
/// scrollback.
pub const Decryptor = struct {
    in: *std.Io.Reader,
    key: Key,
    nonce_prefix: [nonce_prefix_len]u8,
    counter: u64 = 0,
    done: bool = false,

    reader: std.Io.Reader,
    plain: [chunk_len]u8 = undefined,

    const vtable: std.Io.Reader.VTable = .{ .stream = stream };

    /// Reads and checks the header. Must be built in place.
    pub fn init(self: *Decryptor, in: *std.Io.Reader, key: Key) !void {
        const header = in.takeArray(header_len) catch return error.BadParkMagic;
        if (!std.mem.eql(u8, header[0..magic.len], magic)) return error.BadParkMagic;

        self.* = .{
            .in = in,
            .key = key,
            .nonce_prefix = undefined,
            .reader = .{
                .vtable = &vtable,
                // Decrypted bytes land here and the framework serves them from
                // it; see the note in `stream`.
                .buffer = &self.plain,
                .seek = 0,
                .end = 0,
            },
        };
        @memcpy(&self.nonce_prefix, header[magic.len..][0..nonce_prefix_len]);
    }

    /// Decrypt one chunk into `reader.buffer`.
    ///
    /// Returns zero having filled the buffer rather than writing to `w`, which
    /// `Reader.VTable.stream` explicitly allows: "the implementation may choose
    /// to store data in `buffer`, modifying `seek` and `end` accordingly". One
    /// chunk per call keeps the work bounded and the framework does the rest.
    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        _ = w;
        _ = limit;
        const self: *Decryptor = @fieldParentPtr("reader", r);
        if (self.done) return error.EndOfStream;

        const len_bytes = self.in.takeArray(4) catch return error.ReadFailed;
        const len = std.mem.readInt(u32, len_bytes, .little);
        if (len > chunk_len) return error.ReadFailed;

        const cipher = self.in.take(len) catch return error.ReadFailed;
        // Copied out because the next `take` may rebase the source's buffer.
        var cipher_buf: [chunk_len]u8 = undefined;
        @memcpy(cipher_buf[0..len], cipher);
        const tag = self.in.takeArray(tag_len) catch return error.ReadFailed;

        // An empty chunk is the terminator, and is authenticated under the
        // final marker. Anything else there means the file was cut.
        const ad: []const u8 = if (len == 0) &ad_final else &ad_data;
        Aead.decrypt(
            self.plain[0..len],
            cipher_buf[0..len],
            tag.*,
            ad,
            nonceFor(self.nonce_prefix, self.counter),
            self.key,
        ) catch return error.ReadFailed;
        self.counter += 1;

        if (len == 0) {
            self.done = true;
            return error.EndOfStream;
        }

        r.seek = 0;
        r.end = len;
        return 0;
    }
};

/// Whether `bytes` begins a park file this build wrote.
///
/// Used to tell an encrypted store from one written before F3 landed, so an
/// upgrade does not silently lose everybody's parked terminals.
pub fn isEncrypted(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], magic);
}

// -- the key ---------------------------------------------------------------

/// Load the park key, generating one on first use.
///
/// Mode 0600, beside the store it protects. See the note at the top of this
/// file about what that does and does not buy.
pub fn loadOrCreateKey(io: std.Io, path: []const u8) !Key {
    const cwd: std.Io.Dir = .cwd();

    if (cwd.openFile(io, path, .{})) |file| {
        defer file.close(io);
        var key: Key = undefined;
        var buf: [Aead.key_length + 1]u8 = undefined;
        var reader = file.reader(io, &buf);
        reader.interface.readSliceAll(&key) catch return error.BadParkKey;
        return key;
    } else |_| {}

    var key: Key = undefined;
    try io.randomSecure(&key);

    // Exclusive create, so two daemons racing on first start cannot each write
    // a key and leave one of them unable to read the other's park files.
    const file = cwd.createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Somebody won the race. Theirs is the key.
            const existing = try cwd.openFile(io, path, .{});
            defer existing.close(io);
            var buf: [Aead.key_length + 1]u8 = undefined;
            var reader = existing.reader(io, &buf);
            reader.interface.readSliceAll(&key) catch return error.BadParkKey;
            return key;
        },
        else => return err,
    };
    defer file.close(io);

    // Before the bytes go in, so there is no window in which the key exists
    // and is readable by anyone else.
    try file.setPermissions(io, owner_only);

    var out_buf: [Aead.key_length]u8 = undefined;
    var writer = file.writer(io, &out_buf);
    try writer.interface.writeAll(&key);
    try writer.interface.flush();
    try file.sync(io);
    return key;
}

/// `0600`. The one file in the state directory that must not be group- or
/// world-readable, since everything else there is encrypted with it.
const owner_only: std.Io.File.Permissions = @enumFromInt(0o600);

// -- tests -----------------------------------------------------------------

const testing = std.testing;

/// Encrypt `plain` and return the file bytes. Caller owns them.
fn sealForTest(gpa: Allocator, key: Key, plain: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &out);

    var enc: Encryptor = undefined;
    enc.init(&aw.writer, key, @splat(0x5A));
    try enc.writeHeader();
    try enc.writer.writeAll(plain);
    try enc.writer.flush();
    try enc.finish();
    try aw.writer.flush();

    out = aw.toArrayList();
    return out.toOwnedSlice(gpa);
}

/// Decrypt `sealed` and return the plaintext. Caller owns it.
fn openForTest(gpa: Allocator, key: Key, sealed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(sealed);
    var dec: Decryptor = undefined;
    try dec.init(&in, key);

    var out: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &out);
    _ = dec.reader.streamRemaining(&aw.writer) catch {
        // Whatever was decrypted before the failure is not ours to keep, and
        // the allocating writer owns it until it is taken back.
        out = aw.toArrayList();
        out.deinit(gpa);
        return error.ParkAuthFailed;
    };
    try aw.writer.flush();
    out = aw.toArrayList();
    return out.toOwnedSlice(gpa);
}

test "a park stream round trips across every chunk boundary" {
    const gpa = testing.allocator;
    const key: Key = @splat(7);

    // Empty, well under a chunk, exactly one chunk, one byte over, and several
    // chunks with a partial tail.
    for ([_]usize{ 0, 1, 100, chunk_len - 1, chunk_len, chunk_len + 1, chunk_len * 3 + 77 }) |len| {
        const plain = try gpa.alloc(u8, len);
        defer gpa.free(plain);
        for (plain, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

        const sealed = try sealForTest(gpa, key, plain);
        defer gpa.free(sealed);
        const opened = try openForTest(gpa, key, sealed);
        defer gpa.free(opened);

        try testing.expectEqualSlices(u8, plain, opened);
    }
}

test "the plaintext is not in the file" {
    const gpa = testing.allocator;
    const key: Key = @splat(9);

    // Deliberately compressible and deliberately distinctive: this is the
    // shape of the thing F3 exists for, a secret sitting in scrollback.
    const secret = "AKIAIOSFODNN7EXAMPLE wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
    const plain = secret ** 40;

    const sealed = try sealForTest(gpa, key, plain);
    defer gpa.free(sealed);

    try testing.expect(isEncrypted(sealed));
    try testing.expect(std.mem.indexOf(u8, sealed, secret) == null);
    try testing.expect(std.mem.indexOf(u8, sealed, "AKIA") == null);
}

test "a wrong key does not open it" {
    const gpa = testing.allocator;
    const sealed = try sealForTest(gpa, @splat(1), "the quick brown fox" ** 500);
    defer gpa.free(sealed);
    try testing.expectError(error.ParkAuthFailed, openForTest(gpa, @splat(2), sealed));
}

test "a flipped bit anywhere is caught" {
    const gpa = testing.allocator;
    const key: Key = @splat(3);
    const sealed = try sealForTest(gpa, key, "payload" ** 4000);
    defer gpa.free(sealed);

    // Every part of the file: the nonce prefix, a length, ciphertext, a tag.
    for ([_]usize{ magic.len, header_len, header_len + 6, sealed.len - 1 }) |at| {
        const damaged = try gpa.dupe(u8, sealed);
        defer gpa.free(damaged);
        damaged[at] ^= 0x40;
        try testing.expectError(error.ParkAuthFailed, openForTest(gpa, key, damaged));
    }
}

test "a truncated file is not read as a short one" {
    const gpa = testing.allocator;
    const key: Key = @splat(5);
    const plain = "line of scrollback\n" ** 6000;
    const sealed = try sealForTest(gpa, key, plain);
    defer gpa.free(sealed);
    try testing.expect(sealed.len > chunk_len * 3);

    // Cut after a whole number of chunks, so every byte that is there is
    // valid and authenticates. Without the terminator this is exactly the
    // failure that would otherwise look like a terminal with less history --
    // plausible, wrong, and silent.
    const whole_chunk = 4 + chunk_len + tag_len;
    const cut = header_len + whole_chunk * 2;
    try testing.expectError(error.ParkAuthFailed, openForTest(gpa, key, sealed[0..cut]));
}

test "a reordered chunk is caught" {
    const gpa = testing.allocator;
    const key: Key = @splat(11);
    const sealed = try sealForTest(gpa, key, "abcdefgh" ** 20000);
    defer gpa.free(sealed);

    const whole_chunk = 4 + chunk_len + tag_len;
    try testing.expect(sealed.len > header_len + whole_chunk * 2);

    // Swap the first two chunks. Each is intact and authentic in itself; what
    // rejects them is the chunk index being part of the nonce.
    const swapped = try gpa.dupe(u8, sealed);
    defer gpa.free(swapped);
    const a = header_len;
    const b = header_len + whole_chunk;
    for (0..whole_chunk) |i| std.mem.swap(u8, &swapped[a + i], &swapped[b + i]);

    try testing.expectError(error.ParkAuthFailed, openForTest(gpa, key, swapped));
}

test "a file that is not ours is recognised rather than misread" {
    const gpa = testing.allocator;
    var in: std.Io.Reader = .fixed("not a park file at all, just some bytes");
    var dec: Decryptor = undefined;
    try testing.expectError(error.BadParkMagic, dec.init(&in, @splat(0)));

    // Which is the check the legacy path uses, so that upgrading does not
    // silently discard park files written before F3.
    try testing.expect(!isEncrypted("GHOSTSNP\x01\x00"));
    const sealed = try sealForTest(gpa, @splat(0), "x");
    defer gpa.free(sealed);
    try testing.expect(isEncrypted(sealed));
}

test "a key is created once, restricted, and read back" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/illogical-key-{d}", .{std.c.getpid()});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/park.key", .{dir});

    const first = try loadOrCreateKey(io, path);
    const second = try loadOrCreateKey(io, path);
    try testing.expectEqualSlices(u8, &first, &second);

    // Not all zeroes, which is what a silently-failed generation would leave.
    try testing.expect(!std.mem.allEqual(u8, &first, 0));

    // Owner only. The whole point of the file is that it is the one thing in
    // the state directory that must not be readable by anyone else.
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    // Masked, because `permissions` carries the file-type bits too.
    try testing.expectEqual(
        @as(u32, 0o600),
        @as(u32, @intCast(@intFromEnum(stat.permissions))) & 0o777,
    );
}

test "each file gets its own nonce prefix" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const key: Key = @splat(4);
    var prefixes: [8][nonce_prefix_len]u8 = undefined;
    for (&prefixes) |*prefix| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &out);
        var enc: Encryptor = undefined;
        try enc.initRandom(io, &aw.writer, key);
        try enc.writeHeader();
        try enc.finish();
        try aw.writer.flush();
        out = aw.toArrayList();
        @memcpy(prefix, out.items[magic.len..][0..nonce_prefix_len]);
    }

    // Repeating one under the same key would reuse the whole nonce sequence,
    // which for a stream cipher is the failure that loses the plaintext.
    for (prefixes, 0..) |a, i| {
        for (prefixes[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, &a, &b));
        }
    }
}
