//  SnapshotRestore.swift
//  Two-phase restore of a GHOSTSNP stream from the server.
//
//  Phase 1 (`ready`) yields a renderable terminal from the snapshot's active
//  screen. That is the frame the user sees, and it costs O(screen) regardless
//  of how much scrollback the session has.
//
//  Phase 2 (`restoreNextHistoryPage`) prepends scrollback a page at a time,
//  newest first, and may be interleaved with live output.

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

final class SnapshotRestore {
    private var decoder: GhosttySnapshotDecoder?
    private let bytes: [UInt8]

    init(snapshot: Data) throws {
        self.bytes = [UInt8](snapshot)
        var decoder: GhosttySnapshotDecoder?
        try self.bytes.withUnsafeBufferPointer { buffer in
            try check("ghostty_snapshot_decoder_new_buf") {
                ghostty_snapshot_decoder_new_buf(
                    nil, &decoder, buffer.baseAddress, buffer.count)
            }
        }
        self.decoder = decoder
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

    /// Prepend one page of scrollback. Returns false once FINISH is reached.
    @discardableResult
    func restoreNextHistoryPage() throws -> Bool {
        guard let decoder else { return false }
        let result = ghostty_snapshot_decoder_next(decoder)
        switch result {
        case GHOSTTY_SUCCESS: return true
        case GHOSTTY_NO_VALUE: return false
        default:
            throw GhosttyError(result: result, operation: "ghostty_snapshot_decoder_next")
        }
    }
}
