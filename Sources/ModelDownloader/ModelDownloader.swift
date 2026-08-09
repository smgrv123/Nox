import CryptoKit
import Foundation
import ModelProvisioning

/// Why `ModelDownloader.download` threw. A completed-but-corrupt transfer is never a throw
/// (it surfaces as a `ModelVerification.mismatch` return value instead) — this covers only
/// transport-level failures the caller couldn't have anticipated from `ResumePlan` alone.
public enum ModelDownloaderError: Error, Equatable, Sendable {
    case unexpectedResponse(statusCode: Int?)
}

/// The real resumable ranged-HTTP-GET shell (specs/P2a §"Effectful shells"; docs/05-lld.md
/// §2.7; User Stories 12, 13, 14) — **the one allowed network egress** in P2a. Executes the
/// `ResumePlan` computed from the on-disk `.download-state.json` + partial file, streams
/// bytes to disk, hashes them **as they stream** (primed with any already-on-disk prefix on
/// a resume, so a resumed transfer never needs a second full-file read pass to verify),
/// persists `.download-state.json` atomically after every write (via
/// `ModelProvisioning.DownloadStateStore`, itself built on `Persistence.AtomicFileWriter`),
/// and returns the resulting `ModelVerification` — never a silent "probably fine".
///
/// Kept out of the pure `ModelProvisioning` module (which stays free of `URLSession`) and
/// out of the fast unit gate's *production* path — but unlike `WhisperSTTEngine` (which
/// needs a real multi-GB model and is opt-in only), this type's own logic is fully testable
/// headlessly against a `URLProtocol` stub fixture, so its suite runs in the normal
/// `swift test` gate (see `ModelDownloaderTests`).
public final class ModelDownloader: ModelDownloading, @unchecked Sendable {
    private let session: URLSession
    private let resolveURL: @Sendable (ModelDescriptor) -> URL
    private let downloadStateStore: DownloadStateStore
    private let fileManager: FileManager
    /// How many streamed bytes accumulate before a write + a `.download-state.json` save.
    /// Small enough that a real multi-hundred-MB download checkpoints frequently (an
    /// interruption loses at most one chunk's worth of already-received-but-unflushed
    /// bytes), large enough to avoid an atomic-rename storm.
    private let writeChunkSize: Int

    public init(
        session: URLSession = .shared,
        resolveURL: @escaping @Sendable (ModelDescriptor) -> URL = { ModelDownloader.huggingFaceURL(for: $0) },
        downloadStateStore: DownloadStateStore = DownloadStateStore(),
        fileManager: FileManager = .default,
        writeChunkSize: Int = 256 * 1024
    ) {
        self.session = session
        self.resolveURL = resolveURL
        self.downloadStateStore = downloadStateStore
        self.fileManager = fileManager
        self.writeChunkSize = writeChunkSize
    }

    /// The production source: Hugging Face's `resolve` endpoint for the descriptor's
    /// pinned `repo`/`pinnedRevision`/`filename`. Together with the descriptor's own
    /// checksum, this is the **only** network-facing constant in P2a (specs/P2a
    /// §"Storage"; local-first invariant).
    public static func huggingFaceURL(for descriptor: ModelDescriptor) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(descriptor.repo)/resolve/\(descriptor.pinnedRevision)/\(descriptor.filename)"
        guard let url = components.url else {
            preconditionFailure("malformed Hugging Face URL for \(descriptor.repo)/\(descriptor.filename)")
        }
        return url
    }

    // MARK: - ModelDownloading

    public func download(
        descriptor: ModelDescriptor,
        into modelsDirectory: ModelsDirectory,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> ModelVerification {
        try modelsDirectory.create(using: fileManager)
        let blobURL = modelsDirectory.blobURL(for: descriptor)
        let stateURL = modelsDirectory.downloadStateURL

        let state = try? downloadStateStore.load(from: stateURL)
        let plan = ResumePlan.compute(
            descriptor: descriptor, state: state, partialFileSize: currentFileSize(at: blobURL))

        switch plan {
        case .resume(let range):
            return try await streamAndVerify(
                range: range, descriptor: descriptor, blobURL: blobURL, stateURL: stateURL, onProgress: onProgress)

        case .restart:
            discardPartial(blobURL: blobURL, stateURL: stateURL)
            return try await streamAndVerify(
                range: ByteRange(offset: 0, totalSize: descriptor.byteSize),
                descriptor: descriptor, blobURL: blobURL, stateURL: stateURL, onProgress: onProgress)

        case .complete:
            // Nothing left to fetch by size, but `ResumePlan` never inspects content — the
            // caller (`ModelProvisioner`) only reaches the downloader when its own
            // pre-check already found the blob NOT verified, so a same-size `.complete`
            // file here is same-size-but-corrupt. Self-heal with a clean restart rather
            // than reporting the same failure forever on every retry.
            let existing = ModelVerification.verify(fileAt: blobURL, descriptor: descriptor, fileManager: fileManager)
            if existing == .verified { return existing }
            discardPartial(blobURL: blobURL, stateURL: stateURL)
            return try await streamAndVerify(
                range: ByteRange(offset: 0, totalSize: descriptor.byteSize),
                descriptor: descriptor, blobURL: blobURL, stateURL: stateURL, onProgress: onProgress)
        }
    }

    // MARK: - Streaming (the ranged GET, hash-as-you-stream, checkpointed state)

    private func streamAndVerify(
        range: ByteRange,
        descriptor: ModelDescriptor,
        blobURL: URL,
        stateURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> ModelVerification {
        var hasher = SHA256()
        if range.offset > 0 {
            // Resume: prime the running hash with the bytes already on disk so the final
            // digest covers the WHOLE file without a second full-file read pass.
            try primeHasher(&hasher, withPrefixOf: blobURL, count: range.offset)
        } else {
            // Fresh start: discard any stale content so a short-circuited earlier attempt
            // never leaks bytes into this one.
            fileManager.createFile(atPath: blobURL.path, contents: nil)
        }

        var request = URLRequest(url: resolveURL(descriptor))
        request.setValue(range.httpRangeHeaderValue, forHTTPHeaderField: "Range")

        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ModelDownloaderError.unexpectedResponse(statusCode: (response as? HTTPURLResponse)?.statusCode)
        }

        let handle = try FileHandle(forWritingTo: blobURL)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()

        var written = range.offset
        var buffer: [UInt8] = []
        buffer.reserveCapacity(writeChunkSize)

        func flush() throws {
            guard !buffer.isEmpty else { return }
            let chunk = Data(buffer)
            try handle.write(contentsOf: chunk)
            hasher.update(data: chunk)
            written += Int64(chunk.count)
            buffer.removeAll(keepingCapacity: true)
            // Checkpoint atomically so a resume after THIS point always agrees with what's
            // actually on disk (`ResumePlan`'s exact-offset-match contract).
            try downloadStateStore.save(
                DownloadState(offset: written, expectedSHA256: descriptor.expectedSHA256), to: stateURL)
            onProgress(written, descriptor.byteSize)
        }

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= writeChunkSize {
                try flush()
            }
        }
        try flush()

        let digestHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ModelVerification.verify(streamedSHA256: digestHex, byteCount: written, descriptor: descriptor)
    }

    /// Feed the hasher with the first `count` bytes already on disk at `url` (chunked, so a
    /// resume of a multi-hundred-MB partial never loads it fully into memory at once).
    private func primeHasher(_ hasher: inout SHA256, withPrefixOf url: URL, count: Int64) throws {
        guard count > 0 else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var remaining = count
        let chunkSize = 1 << 20  // 1 MB
        while remaining > 0 {
            let toRead = Int(min(Int64(chunkSize), remaining))
            guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
    }

    private func currentFileSize(at url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? Int64) ?? 0
    }

    private func discardPartial(blobURL: URL, stateURL: URL) {
        try? fileManager.removeItem(at: blobURL)
        try? fileManager.removeItem(at: stateURL)
    }
}
