//  GhosttyTerminal.swift
//  A Swift-owned libghostty-vt terminal.
//
//  This is the whole reason the client is native: the server ships us raw,
//  unprocessed PTY bytes and a `GHOSTSNP` snapshot, and libghostty-vt — the
//  exact VT implementation Ghostty itself uses — turns them into grid state we
//  can draw. Nothing here reimplements a terminal.

import Foundation
import GhosttyVt

/// A libghostty-vt error surfaced as a Swift error.
public struct GhosttyError: Error, CustomStringConvertible {
    public let result: GhosttyResult
    public let operation: String

    public var description: String {
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

/// Owns a `GhosttyTerminal` handle.
///
/// Not `Sendable` on purpose: libghostty-vt requires that a terminal is not
/// mutated concurrently. Each session's terminal lives on its own actor.
public final class Terminal {
    private(set) var handle: GhosttyVt.GhosttyTerminal?

    public init(cols: UInt16, rows: UInt16) throws {
        var handle: GhosttyVt.GhosttyTerminal?
        try check("ghostty_terminal_new") {
            ghostty_terminal_new(nil, &handle, cols, rows)
        }
        self.handle = handle
    }

    /// Adopt a terminal produced by a snapshot decoder.
    init(adopting handle: GhosttyVt.GhosttyTerminal) {
        self.handle = handle
    }

    deinit {
        if let handle { ghostty_terminal_free(handle) }
    }

    /// Feed unprocessed PTY bytes straight from the wire.
    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard let handle, let base = bytes.baseAddress else { return }
        ghostty_terminal_vt_write(
            handle,
            base.assumingMemoryBound(to: UInt8.self),
            bytes.count
        )
    }

    public func write(_ data: Data) {
        data.withUnsafeBytes { write($0) }
    }

    /// Resize the grid. Cell pixel dimensions are forwarded so that the image
    /// protocols and in-band size reports stay correct.
    public func resize(
        cols: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32
    ) throws {
        guard let handle else { return }
        try check("ghostty_terminal_resize") {
            ghostty_terminal_resize(handle, cols, rows, cellWidthPx, cellHeightPx)
        }
    }
}

/// Two-phase restore of a `GHOSTSNP` stream.
///
/// Phase 1 (`ready`) yields a renderable terminal from the snapshot's active
/// screen — this is the "instant current screen" path, both when unparking on
/// the server and when attaching from a client. Phase 2 (`restoreNextHistoryPage`)
/// prepends scrollback a page at a time and can be interleaved with live output.
///
/// - Note: This scaffold decodes from a fully-buffered snapshot. The streaming
///   form uses `ghostty_snapshot_decoder_new` with a `GhosttyReader` callback so
///   that decoding overlaps with the network read. See docs/PROTOCOL.md.
public final class SnapshotRestore {
    private var decoder: GhosttySnapshotDecoder?
    private let snapshot: Data

    public init(snapshot: Data) throws {
        self.snapshot = snapshot
        var decoder: GhosttySnapshotDecoder?
        try self.snapshot.withUnsafeBytes { buffer in
            try check("ghostty_snapshot_decoder_new_buf") {
                ghostty_snapshot_decoder_new_buf(
                    nil,
                    &decoder,
                    buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    buffer.count
                )
            }
        }
        self.decoder = decoder
    }

    deinit {
        if let decoder { ghostty_snapshot_decoder_free(decoder) }
    }

    /// Decode through the snapshot's READY marker. Cheap; safe on the path that
    /// paints the first frame.
    public func ready() throws -> Terminal {
        guard let decoder else {
            throw GhosttyError(result: GHOSTTY_INVALID_VALUE, operation: "ready")
        }
        var handle: GhosttyVt.GhosttyTerminal?
        try check("ghostty_snapshot_decoder_ready") {
            ghostty_snapshot_decoder_ready(decoder, &handle)
        }
        return Terminal(adopting: handle!)
    }

    /// Prepend one page of scrollback. Returns false once FINISH is reached.
    ///
    /// Safe to call between frames, and safe to interleave with live writes to
    /// the terminal returned by ``ready()``.
    public func restoreNextHistoryPage() throws -> Bool {
        guard let decoder else { return false }
        let result = ghostty_snapshot_decoder_next(decoder)
        switch result {
        case GHOSTTY_SUCCESS: return true
        case GHOSTTY_NO_VALUE: return false
        default: throw GhosttyError(result: result, operation: "ghostty_snapshot_decoder_next")
        }
    }
}
