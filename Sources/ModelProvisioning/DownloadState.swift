import Foundation
import Persistence

/// The resumable-download bookkeeping persisted as `.download-state.json` (docs/05-lld.md
/// §2.7): how many bytes have landed (`offset`) and the SHA-256 the in-progress blob is
/// pinned to (`expectedSHA256`, so a partial from a superseded pin is discarded, not
/// resumed). Deliberately tiny — the file itself is the source of truth for resume math.
public struct DownloadState: Equatable, Sendable, Codable {
    /// Bytes already written to the partial file (the next request starts here).
    public let offset: Int64
    /// The descriptor SHA-256 this partial belongs to.
    public let expectedSHA256: String

    public init(offset: Int64, expectedSHA256: String) {
        self.offset = offset
        self.expectedSHA256 = expectedSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case offset
        case expectedSHA256 = "expected_sha256"
    }
}

/// Pure (de)serialization of `.download-state.json`. Stable, sorted-key JSON so the file
/// is human-readable and diff-friendly (the §2.7 posture: everything on disk is
/// inspectable).
public enum DownloadStateCodec {
    public static func encode(_ state: DownloadState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    public static func decode(_ data: Data) throws -> DownloadState {
        try JSONDecoder().decode(DownloadState.self, from: data)
    }
}

/// The atomic read/write façade for `.download-state.json`. Every mutation goes through
/// `Persistence.AtomicFileWriter` (a `*.tmp` sibling + `rename(2)`), satisfying the §2.7
/// **Atomicity (MUST)** — a crash mid-write never corrupts the resume bookkeeping, and a
/// reader never sees a half-written file. Reuses the audited writer rather than
/// reinventing atomic writes.
public struct DownloadStateStore: Sendable {
    private let writer: AtomicFileWriter

    public init(writer: AtomicFileWriter = AtomicFileWriter()) {
        self.writer = writer
    }

    /// Atomically persist `state` to `url` (temp-sibling + `rename`).
    public func save(_ state: DownloadState, to url: URL) throws {
        try writer.write(try DownloadStateCodec.encode(state), to: url)
    }

    /// Load the recorded state, or `nil` when no file exists yet (first run / post-restart).
    /// A present-but-corrupt file throws, so the caller can fall back to a clean restart.
    public func load(from url: URL) throws -> DownloadState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try DownloadStateCodec.decode(data)
    }
}
