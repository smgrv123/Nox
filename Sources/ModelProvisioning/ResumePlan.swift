import Foundation

/// A contiguous byte range to request next, `[offset, totalSize)` (docs/05-lld.md §2.7).
/// Carries the HTTP `Range` header string so the risky format lives in the tested pure
/// module, not the effectful downloader.
public struct ByteRange: Equatable, Sendable {
    /// First byte to request, inclusive (the resume point).
    public let offset: Int64
    /// The descriptor's full size; the exclusive end of the range.
    public let totalSize: Int64

    public init(offset: Int64, totalSize: Int64) {
        self.offset = offset
        self.totalSize = totalSize
    }

    /// Bytes still to fetch.
    public var count: Int64 { totalSize - offset }

    /// The value for a ranged `GET`'s `Range:` header, e.g. `bytes=400-999` (last byte is
    /// `totalSize - 1`, inclusive per RFC 7233).
    public var httpRangeHeaderValue: String { "bytes=\(offset)-\(totalSize - 1)" }
}

/// The resumable-download decision (docs/05-lld.md §2.7; User Story 13). Pure math over
/// the recorded `.download-state.json` and the partial file's actual size — the effectful
/// `ModelDownloader` (Phase 5) executes the plan but owns none of this logic.
public enum ResumePlan: Equatable, Sendable {
    /// The blob is already whole (size-wise) → request nothing. Integrity is confirmed
    /// separately by `ModelVerification`.
    case complete
    /// Fetch this range and append it to the partial file.
    case resume(ByteRange)
    /// The on-disk state is inconsistent, oversized, or pinned to a different model →
    /// discard the partial file + state and start clean. The safe, fail-closed direction.
    case restart

    /// Decide the next action for `descriptor` given the recorded `state` (or `nil` if no
    /// `.download-state.json`) and `partialFileSize` (bytes currently on disk, `0` if none).
    public static func compute(
        descriptor: ModelDescriptor,
        state: DownloadState?,
        partialFileSize: Int64
    ) -> ResumePlan {
        let expected = descriptor.byteSize
        // An unpinned / zero-size descriptor isn't downloadable yet (pins land in P5).
        guard expected > 0 else { return .restart }

        guard let state else {
            // No bookkeeping: only a whole-sized file can be trusted as complete; any
            // other partial is untrustworthy without a recorded offset, so start over.
            if partialFileSize == expected { return .complete }
            if partialFileSize == 0 { return .resume(ByteRange(offset: 0, totalSize: expected)) }
            return .restart
        }

        // The recorded download must be for THIS pinned artifact.
        guard state.expectedSHA256 == descriptor.expectedSHA256 else { return .restart }
        // The offset must be within the whole file (negative or oversized ⇒ inconsistent).
        guard state.offset >= 0, state.offset <= expected else { return .restart }
        // The recorded offset must equal the bytes actually on disk.
        guard state.offset == partialFileSize else { return .restart }

        if state.offset == expected { return .complete }
        return .resume(ByteRange(offset: state.offset, totalSize: expected))
    }
}
