import Foundation

/// The seam between the pure provisioning core and the effectful, network-touching
/// downloader (docs/05-lld.md §2.7; specs/P2a §"Effectful shells"; Phase 5). The real
/// conformer (`ModelDownloader`, a separate app-linked module) executes a resumable
/// ranged HTTP GET; this protocol lets `ModelProvisioner` be tested headlessly with a
/// fake, and keeps `ModelProvisioning` itself free of `URLSession`/networking.
///
/// A conformer is expected to: resolve a `ResumePlan` from the on-disk state + partial
/// file, stream bytes to `modelsDirectory`'s blob path (skipping the network entirely
/// when already complete), update `.download-state.json` atomically as it progresses,
/// and return the resulting `ModelVerification` — so the caller never has to re-hash a
/// multi-hundred-MB file it just finished streaming.
public protocol ModelDownloading: Sendable {
    /// Fetch (or resume fetching) `descriptor`'s blob into `modelsDirectory`, reporting
    /// `(bytesWritten, totalBytes)` as it streams, and return the post-transfer
    /// `ModelVerification` outcome. Throws only on a transport-level failure (e.g. the
    /// connection dropped) — a completed-but-corrupt transfer is a `.mismatch`, not a throw.
    func download(
        descriptor: ModelDescriptor,
        into modelsDirectory: ModelsDirectory,
        onProgress: @escaping @Sendable (_ bytesWritten: Int64, _ totalBytes: Int64) -> Void
    ) async throws -> ModelVerification
}
