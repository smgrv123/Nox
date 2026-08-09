import CryptoKit
import Foundation

/// The on-disk integrity decision for a provisioned model (docs/05-lld.md §2.7; User Story
/// 14): does the blob match its pinned `ModelDescriptor`?
///
/// **Posture (shared with the Dangerous-Command Scanner):** a false `verified` on a
/// corrupt/mismatched/unpinned file is a **defect**, never a tolerated edge. `verified` is
/// returned only when the descriptor is pinned **and** both the byte size and the SHA-256
/// match. Every other outcome fails closed (`mismatch` / `absent`), so the caller
/// re-provisions rather than loading a bad model.
public enum ModelVerification: Equatable, Sendable {
    /// Size and SHA-256 both match a pinned descriptor.
    case verified
    /// The blob is present but does not match the descriptor.
    case mismatch(Mismatch)
    /// No file at the expected path (never downloaded, or wiped).
    case absent

    /// Why a present blob failed. Preserved for an honest, human-readable failure state
    /// (User Story 19) and for the future download-retry decision.
    public enum Mismatch: Equatable, Sendable {
        case size(expected: Int64, actual: Int64)
        case hash(expected: String, actual: String)
    }

    /// Verify a file on disk against `descriptor`. Reading the injected file URL is the
    /// only I/O; the decision itself is pure and routed through `verify(streamedSHA256:…)`
    /// so file-fed and stream-fed verification share one source of truth.
    public static func verify(
        fileAt url: URL,
        descriptor: ModelDescriptor,
        fileManager: FileManager = .default
    ) -> ModelVerification {
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .absent }
        return verify(
            streamedSHA256: sha256Hex(of: data),
            byteCount: Int64(data.count),
            descriptor: descriptor)
    }

    /// Verify an already-computed size + SHA-256 (what the resumable downloader produces as
    /// it streams bytes to disk) against `descriptor`. Pure; no I/O.
    public static func verify(
        streamedSHA256 hex: String,
        byteCount: Int64,
        descriptor: ModelDescriptor
    ) -> ModelVerification {
        // Fail closed on an unpinned descriptor: without a real pin there is nothing to
        // trust, so no blob may be reported verified against it.
        guard descriptor.isPinned else {
            return .mismatch(.hash(expected: descriptor.expectedSHA256, actual: hex))
        }
        guard byteCount == descriptor.byteSize else {
            return .mismatch(.size(expected: descriptor.byteSize, actual: byteCount))
        }
        guard hex.lowercased() == descriptor.expectedSHA256.lowercased() else {
            return .mismatch(.hash(expected: descriptor.expectedSHA256, actual: hex))
        }
        return .verified
    }

    /// Lowercase hex SHA-256 of `data` (CryptoKit; Metal-free, deterministic).
    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
