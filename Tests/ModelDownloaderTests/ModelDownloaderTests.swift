import CryptoKit
import Foundation
import ModelProvisioning
import XCTest

@testable import ModelDownloader

/// Headless tests for the real resumable-download shell (specs/P2a Phase 5; User Stories
/// 12, 13, 14). Exercised against `StubURLProtocol` — an in-process fake HTTP server — never
/// the real network or a production model (see `StubURLProtocol`'s doc comment for why a
/// `URLProtocol` stub was chosen over a local `http.server` process).
final class ModelDownloaderTests: XCTestCase {

    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appending(path: "aide-downloader-\(UUID().uuidString)", directoryHint: .isDirectory)
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: directory)
        StubURLProtocol.reset()
    }

    // MARK: - Fixtures

    /// A small (~2.4 MB), fully deterministic pseudo-random blob — no external file, no
    /// real model, reproducible byte-for-byte across runs.
    private func fixtureBytes(count: Int, seed: UInt32 = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: (UInt32($0) &+ seed) &* 2_654_435_761) })
    }

    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func descriptor(for bytes: Data, filename: String = "fixture.bin") -> ModelDescriptor {
        ModelDescriptor(
            repo: "test/repo",
            pinnedRevision: "rev",
            filename: filename,
            expectedSHA256: sha256Hex(of: bytes),
            byteSize: Int64(bytes.count),
            onDiskRelativePath: filename)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeSUT(writeChunkSize: Int = 64 * 1024) -> ModelDownloader {
        ModelDownloader(
            session: makeSession(),
            resolveURL: { _ in URL(string: "https://example.invalid/model.bin")! },
            writeChunkSize: writeChunkSize)
    }

    /// Parse `bytes=<offset>-<end>` → `offset`; `nil` if the request carried no Range header.
    private func rangeOffset(of request: URLRequest) -> Int? {
        guard let value = request.value(forHTTPHeaderField: "Range"),
            value.hasPrefix("bytes="),
            let dash = value.firstIndex(of: "-")
        else { return nil }
        return Int(value[value.index(value.startIndex, offsetBy: 6)..<dash])
    }

    // MARK: - Full download: streams to disk, verifies

    func testFullDownloadStreamsToDiskAndVerifies() async throws {
        let bytes = fixtureBytes(count: 2_400_137)
        let sut = descriptor(for: bytes)
        let modelsDirectory = ModelsDirectory(containerRoot: directory)

        var seenRanges: [String?] = []
        StubURLProtocol.handler = { request in
            seenRanges.append(request.value(forHTTPHeaderField: "Range"))
            return StubURLProtocol.Response(statusCode: 200, body: bytes)
        }

        let downloader = makeSUT()
        let progress = ProgressRecorder()
        let result = try await downloader.download(descriptor: sut, into: modelsDirectory) { written, total in
            progress.record((written, total))
        }

        XCTAssertEqual(result, .verified)
        XCTAssertEqual(seenRanges, ["bytes=0-\(bytes.count - 1)"], "a fresh download requests the whole file")
        XCTAssertFalse(progress.all.isEmpty, "progress must be reported as bytes stream in")
        XCTAssertEqual(progress.all.last?.0, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: modelsDirectory.blobURL(for: sut)), bytes)
    }

    // MARK: - Interrupted mid-stream → resume from the recorded offset → completes & verifies

    func testInterruptedDownloadResumesFromRecordedOffsetAndCompletes() async throws {
        let bytes = fixtureBytes(count: 3_000_071)
        let sut = descriptor(for: bytes)
        let modelsDirectory = ModelsDirectory(containerRoot: directory)
        let cutoff = 1_200_003  // interrupt partway through the first attempt

        var seenRanges: [Int] = []
        StubURLProtocol.handler = { request in
            let offset = self.rangeOffset(of: request) ?? 0
            seenRanges.append(offset)
            if offset == 0 {
                // Simulate a dropped connection after delivering only the first `cutoff`
                // bytes, in several pieces (not one instantaneous burst) so the consumer
                // genuinely observes a mid-stream interruption.
                let firstAttempt = bytes.prefix(cutoff)
                let pieceSize = 100_000
                var pieces: [Data] = []
                var start = firstAttempt.startIndex
                while start < firstAttempt.endIndex {
                    let end = min(start + pieceSize, firstAttempt.endIndex)
                    pieces.append(Data(firstAttempt[start..<end]))
                    start = end
                }
                return StubURLProtocol.Response(
                    statusCode: 206, chunks: pieces, failure: URLError(.networkConnectionLost))
            }
            return StubURLProtocol.Response(statusCode: 206, body: bytes.suffix(from: offset))
        }

        let downloader = makeSUT()

        // First attempt: interrupted, must throw.
        do {
            _ = try await downloader.download(descriptor: sut, into: modelsDirectory) { _, _ in }
            XCTFail("expected the simulated dropped connection to throw")
        } catch {
            // expected
        }

        let blobURL = modelsDirectory.blobURL(for: sut)
        let partialSize = try XCTUnwrap(fileManager.attributesOfItem(atPath: blobURL.path)[.size] as? Int)
        XCTAssertGreaterThan(partialSize, 0, "bytes flushed before the interruption must survive on disk")
        XCTAssertLessThan(partialSize, bytes.count, "the partial file must not already be complete")

        // A `.download-state.json` matching the partial file must exist for `ResumePlan` to trust it.
        let stateStore = DownloadStateStore()
        let state = try XCTUnwrap(stateStore.load(from: modelsDirectory.downloadStateURL))
        XCTAssertEqual(state.offset, Int64(partialSize))
        XCTAssertEqual(state.expectedSHA256, sut.expectedSHA256)
        // Atomicity: no `.tmp` sibling left behind by the interrupted attempt's state writes.
        let survivors = try fileManager.contentsOfDirectory(atPath: modelsDirectory.url.path)
        XCTAssertFalse(survivors.contains { $0.hasSuffix(".tmp") }, "a temp sibling leaked: \(survivors)")

        // Second attempt: resumes from exactly the recorded offset and completes.
        let result = try await downloader.download(descriptor: sut, into: modelsDirectory) { _, _ in }

        XCTAssertEqual(result, .verified)
        XCTAssertEqual(try Data(contentsOf: blobURL), bytes)
        XCTAssertEqual(seenRanges, [0, partialSize], "the resumed request must start exactly at the recorded offset")
    }

    // MARK: - Server byte-mismatch → ModelVerification catches it (not used)

    func testServerByteMismatchIsCaughtByVerificationAndNeverReportedVerified() async throws {
        let correctBytes = fixtureBytes(count: 500_003)
        let wrongBytes = fixtureBytes(count: 500_003, seed: 999)  // same size, different content
        let sut = descriptor(for: correctBytes)  // pinned to the CORRECT bytes' hash
        let modelsDirectory = ModelsDirectory(containerRoot: directory)

        StubURLProtocol.handler = { _ in StubURLProtocol.Response(statusCode: 200, body: wrongBytes) }

        let downloader = makeSUT()
        let result = try await downloader.download(descriptor: sut, into: modelsDirectory) { _, _ in }

        XCTAssertNotEqual(result, .verified, "bytes that don't match the pinned SHA-256 must never verify")
        guard case .mismatch(.hash) = result else {
            return XCTFail("expected a hash mismatch, got \(result)")
        }
    }

    // MARK: - Skip-if-present-and-verified: no network touched at all

    func testAlreadyCompleteAndVerifiedFileSkipsTheNetworkEntirely() async throws {
        let bytes = fixtureBytes(count: 12_345)
        let sut = descriptor(for: bytes)
        let modelsDirectory = ModelsDirectory(containerRoot: directory)
        try modelsDirectory.create(using: fileManager)
        try bytes.write(to: modelsDirectory.blobURL(for: sut))

        StubURLProtocol.handler = { _ in
            XCTFail("an already-complete, already-verified blob must never trigger a network request")
            return StubURLProtocol.Response(statusCode: 500)
        }

        let downloader = makeSUT()
        let result = try await downloader.download(descriptor: sut, into: modelsDirectory) { _, _ in }

        XCTAssertEqual(result, .verified)
    }
}

/// Thread-safe recorder for `onProgress` callbacks, mirroring
/// `ConfigurationTests.SettingsStoreTests.SignalRecorder` (the established pattern for a
/// `@Sendable`-closure-fed recorder in this repo's test suites).
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [(Int64, Int64)] = []

    func record(_ update: (Int64, Int64)) {
        lock.lock()
        defer { lock.unlock() }
        updates.append(update)
    }

    var all: [(Int64, Int64)] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}
