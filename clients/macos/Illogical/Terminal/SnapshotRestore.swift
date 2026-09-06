//  SnapshotRestore.swift
//  Two-phase restore of a GHOSTSNP stream from the server.
//
//  Phase 1 (`ready`) yields a renderable terminal from the snapshot's active
//  screen. That is the frame the user sees, and it costs O(screen) regardless
//  of how much scrollback the session has.
//
//  Phase 2 (`restoreNextHistoryPage`) prepends scrollback a page at a time,
//  newest first, and may be interleaved with live output.
//
//  The decoder pulls its bytes through a `GhosttyReader` rather than decoding a
//  finished buffer, so phase 1 needs only the bytes the server has actually
//  sent — which is the whole point of the server sending `snapshot_ready` at
//  the READY marker instead of after the encode.

import Foundation
import GhosttyVt

struct GhosttyError: Error, CustomStringConvertible {
    let result: GhosttyResult
    let operation: String

    var description: String {
        "libghostty-vt \(operation) failed with result \(result.rawValue)"
    }
}

@inline(__always)
func check(_ operation: String, _ body: () -> GhosttyResult) throws {
    let result = body()
    guard result == GHOSTTY_SUCCESS else {
        throw GhosttyError(result: result, operation: operation)
    }
}

/// The byte pipe between the frame pump and the snapshot decoder.
///
/// Chunks go in as `snapshot_chunk` frames arrive and come out through a
/// `GhosttyReader`. Consumed chunks are released as they are read, so the pipe
/// holds only what the decoder has not reached yet.
///
/// **A starved read reports end of file.** `snapshot.h` gives a source that
/// can starve two options — "wait outside the decoder or block in their
/// callback" — and this takes the first. Blocking is what it must not do:
/// `ready()` runs on the main actor and history decodes under the engine's
/// lock, so a blocked callback stalls the window or the renderer for as long
/// as the transport takes.
///
/// Waiting outside the decoder is what the caller does instead: `ready()` is
/// only called once `snapshot_ready` has arrived, and `next()` only once
/// `snapshot_end` has, so each phase is driven from bytes already in hand. A
/// read that finds nothing therefore means the stream is malformed or was
/// abandoned, and EOF is the honest answer — the decoder reports truncated
/// data and the caller falls back to a blank screen.
final class SnapshotStream: @unchecked Sendable {
    /// The frame pump appends on the main actor; the decoder reads from it
    /// there and then from one background task. Those never overlap, so this
    /// is uncontended — it is here for the memory barrier, not the exclusion.
    private let lock = NSLock()
    private var chunks: [Data] = []
    /// Index of the chunk being read, and how much of it has been consumed.
    private var next = 0
    private var head = 0
    private var closed = false

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        chunks.append(data)
    }

    /// No more bytes are coming. Reads drain what is left, then report EOF.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }

    /// Drop everything and report EOF from here on, so an abandoned decode
    /// stops rather than working through history nobody is going to see.
    func abandon() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        chunks.removeAll(keepingCapacity: false)
        next = 0
        head = 0
    }

    /// Bytes buffered but not yet handed to the decoder.
    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        var total = 0
        for i in next..<chunks.count { total += chunks[i].count }
        return total - head
    }

    var reader: GhosttyReader {
        GhosttyReader(
            read: { userdata, buffer, capacity, outRead in
                guard let userdata, let buffer, let outRead else { return false }
                let stream = Unmanaged<SnapshotStream>.fromOpaque(userdata)
                    .takeUnretainedValue()
                outRead.pointee = stream.read(into: buffer, capacity: capacity)
                return true
            },
            userdata: Unmanaged.passUnretained(self).toOpaque())
    }

    private func read(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }

        var written = 0
        while written < capacity, next < chunks.count {
            let chunk = chunks[next]
            let take = min(capacity - written, chunk.count - head)
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                buffer.advanced(by: written).update(
                    from: base.advanced(by: head).assumingMemoryBound(to: UInt8.self),
                    count: take)
            }
            written += take
            head += take
            if head == chunk.count { advanceLocked() }
        }
        return written
    }

    private func advanceLocked() {
        // Release the bytes now rather than at the next compaction: a large
        // history is most of what this pipe ever holds.
        chunks[next] = Data()
        next += 1
        head = 0
        // Dropping the consumed prefix costs O(remaining), so only do it once
        // the prefix is at least half the array. `removeFirst` on every chunk
        // would make a hundred thousand lines quadratic in chunk count.
        if next >= 32, next * 2 >= chunks.count {
            chunks.removeFirst(next)
            next = 0
        }
    }
}

/// Unchecked because the decoder is not thread-safe and is not made so here:
/// it is used from the main actor through `ready()`, and then handed to
/// exactly one background task for the history pages. What it mutates is the
/// terminal the engine owns, so every call after `ready()` must hold the
/// engine's lock.
final class SnapshotRestore: @unchecked Sendable {
    private var decoder: GhosttySnapshotDecoder?
    let stream: SnapshotStream

    init(stream: SnapshotStream) throws {
        self.stream = stream
        var decoder: GhosttySnapshotDecoder?
        try check("ghostty_snapshot_decoder_new") {
            ghostty_snapshot_decoder_new(nil, &decoder, stream.reader)
        }
        self.decoder = decoder
    }

    /// A snapshot that is already complete in memory. The streaming form is
    /// what the attach path uses; this is for callers that have the bytes.
    convenience init(snapshot: Data) throws {
        let stream = SnapshotStream()
        stream.append(snapshot)
        stream.close()
        try self.init(stream: stream)
    }

    deinit {
        if let decoder { ghostty_snapshot_decoder_free(decoder) }
    }

    /// Decode through the snapshot's READY marker. The returned terminal is
    /// caller-owned and immediately renderable.
    func ready() throws -> GhosttyTerminal {
        guard let decoder else {
            throw GhosttyError(result: GHOSTTY_INVALID_VALUE, operation: "ready")
        }
        var handle: GhosttyTerminal?
        try check("ghostty_snapshot_decoder_ready") {
            ghostty_snapshot_decoder_ready(decoder, &handle)
        }
        guard let handle else {
            throw GhosttyError(result: GHOSTTY_INVALID_VALUE, operation: "ready")
        }
        return handle
    }

    /// How many rows sit above the active area, as the snapshot declares them.
    ///
    /// Available as soon as READY validates, which is what makes a loading
    /// state possible at all: the size of the history is known before a single
    /// page of it has arrived, so the scrollbar can be drawn against the
    /// finished extent from the first frame instead of growing to meet it.
    ///
    /// Advisory, and `snapshot.h` says so. This is what the encoder saw; a
    /// page that can no longer be applied to the live terminal is still
    /// consumed and still reports zero rows. It therefore sizes the region
    /// drawn as pending and is not a promise about what will land, which is
    /// why the count is cleared outright when the restore ends rather than
    /// being trusted to reach zero on its own.
    ///
    /// Zero before READY, and zero for a snapshot with no history.
    var declaredHistoryRows: UInt64 {
        guard let decoder else { return 0 }
        var rows: UInt64 = 0
        guard
            ghostty_snapshot_decoder_get(
                decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_PRIMARY, &rows)
                == GHOSTTY_SUCCESS
        else { return 0 }
        return rows
    }

    /// Prepend one page of scrollback, and report how many rows it added.
    ///
    /// Nil once FINISH is reached. Nil and zero are different answers and the
    /// caller has to keep them apart: a page that was consumed and validated
    /// but could not be applied returns zero, and history continues after it.
    ///
    /// Returning the count rather than a bool alongside a separate progress
    /// query is deliberate. `snapshot.h` requires the PROGRESS values be read
    /// before the next call to next, and a caller that breaks out of its loop
    /// and then reads them gets the previous page's numbers — which for a
    /// pending count means stranding it above zero forever.
    @discardableResult
    func restoreNextHistoryPage() throws -> Int? {
        guard let decoder else { return nil }
        let result = ghostty_snapshot_decoder_next(decoder)
        switch result {
        case GHOSTTY_SUCCESS:
            var rows = 0
            guard
                ghostty_snapshot_decoder_get(
                    decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS, &rows)
                    == GHOSTTY_SUCCESS
            else { return 0 }
            return rows
        case GHOSTTY_NO_VALUE: return nil
        default:
            throw GhosttyError(result: result, operation: "ghostty_snapshot_decoder_next")
        }
    }
}
