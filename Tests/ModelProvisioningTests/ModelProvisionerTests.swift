import XCTest

@testable import ModelProvisioning

/// `ModelProvisioner` is the pure(ish) orchestration of "get this descriptor onto disk and
/// ready to load" (docs/05-lld.md §2.7; specs/P2a Phase 5; User Stories 12, 13, 15, 17, 19):
/// skip-if-already-verified, else download → verify → ready, with every failure mapped to a
/// human-readable `Failure`. Both collaborators are injected protocols
/// (`ModelDownloading`/`ModelVerifying`), so this suite proves the decision logic with fakes —
/// no network, no disk I/O, no real whisper model.
final class ModelProvisionerTests: XCTestCase {

    private let descriptor = ModelDescriptor(
        repo: "ggerganov/whisper.cpp",
        pinnedRevision: "rev",
        filename: "model.bin",
        expectedSHA256: "deadbeef",
        byteSize: 1000,
        onDiskRelativePath: "model.bin")

    private let modelsDirectory = ModelsDirectory(containerRoot: URL(fileURLWithPath: "/tmp/aide-provisioner-fixture"))

    // MARK: - Skip path: already present and verified ⇒ the downloader is never touched

    func testAlreadyVerifiedSkipsTheDownloadEntirely() async {
        let verifier = FakeVerifier(result: .verified)
        let downloader = FakeDownloader(result: .success(.verified))
        let sut = ModelProvisioner(downloader: downloader, verifier: verifier, modelsDirectory: modelsDirectory)

        let recorder = StateRecorder()
        let final = await sut.provision(descriptor: descriptor) { recorder.record($0) }

        XCTAssertEqual(final, .ready(modelsDirectory.blobURL(for: descriptor)))
        XCTAssertEqual(downloader.callCount, 0, "an already-verified model must never trigger a download")
        XCTAssertEqual(recorder.all, [.checking, .ready(modelsDirectory.blobURL(for: descriptor))])
    }

    // MARK: - Download-success path

    func testAbsentModelDownloadsThenVerifiesThenReady() async {
        let verifier = FakeVerifier(result: .absent)
        let downloader = FakeDownloader(result: .success(.verified))
        let sut = ModelProvisioner(downloader: downloader, verifier: verifier, modelsDirectory: modelsDirectory)

        let recorder = StateRecorder()
        let final = await sut.provision(descriptor: descriptor) { recorder.record($0) }

        XCTAssertEqual(final, .ready(modelsDirectory.blobURL(for: descriptor)))
        XCTAssertEqual(downloader.callCount, 1)
        XCTAssertEqual(
            recorder.all,
            [
                .checking,
                .downloading(bytesWritten: 0, totalBytes: descriptor.byteSize),
                .verifying,
                .ready(modelsDirectory.blobURL(for: descriptor)),
            ])
    }

    func testProgressCallbacksFromTheDownloaderAreForwardedAsDownloadingStates() async {
        let verifier = FakeVerifier(result: .absent)
        let downloader = FakeDownloader(result: .success(.verified), progressSteps: [(400, 1000), (1000, 1000)])
        let sut = ModelProvisioner(downloader: downloader, verifier: verifier, modelsDirectory: modelsDirectory)

        let recorder = StateRecorder()
        _ = await sut.provision(descriptor: descriptor) { recorder.record($0) }

        XCTAssertTrue(recorder.all.contains(.downloading(bytesWritten: 400, totalBytes: 1000)))
        XCTAssertTrue(recorder.all.contains(.downloading(bytesWritten: 1000, totalBytes: 1000)))
    }

    // MARK: - Verify-fail path: a corrupt/mismatched download is caught, never used

    func testDownloadedButMismatchedIsSurfacedAsVerificationFailedNotReady() async {
        let mismatch = ModelVerification.Mismatch.hash(expected: "deadbeef", actual: "beefdead")
        let verifier = FakeVerifier(result: .absent)
        let downloader = FakeDownloader(result: .success(.mismatch(mismatch)))
        let sut = ModelProvisioner(downloader: downloader, verifier: verifier, modelsDirectory: modelsDirectory)

        let final = await sut.provision(descriptor: descriptor)

        XCTAssertEqual(final, .failed(.verificationFailed(mismatch)))
        guard case .failed = final else { return XCTFail("a mismatched download must never resolve to .ready") }
    }

    func testNetworkFailureDuringDownloadIsSurfacedAsDownloadFailed() async {
        struct BoomError: Error {}
        let verifier = FakeVerifier(result: .absent)
        let downloader = FakeDownloader(result: .failure(BoomError()))
        let sut = ModelProvisioner(downloader: downloader, verifier: verifier, modelsDirectory: modelsDirectory)

        let final = await sut.provision(descriptor: descriptor)

        guard case .failed(.downloadFailed) = final else { return XCTFail("expected .downloadFailed, got \(final)") }
    }

    // MARK: - Not-ready path: the downloader reports the file is (still) absent

    func testDownloadCompletingWithAbsentIsSurfacedAsNotReady() async {
        let verifier = FakeVerifier(result: .absent)
        let downloader = FakeDownloader(result: .success(.absent))
        let sut = ModelProvisioner(downloader: downloader, verifier: verifier, modelsDirectory: modelsDirectory)

        let final = await sut.provision(descriptor: descriptor)

        XCTAssertEqual(final, .failed(.notReady))
    }
}

// MARK: - Fakes

/// Thread-safe recorder for `onState` callbacks, mirroring `SettingsStoreTests.SignalRecorder`.
private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ModelProvisioner.State] = []

    func record(_ state: ModelProvisioner.State) {
        lock.lock()
        defer { lock.unlock() }
        states.append(state)
    }

    var all: [ModelProvisioner.State] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }
}

private final class FakeVerifier: ModelVerifying {
    let result: ModelVerification
    init(result: ModelVerification) { self.result = result }
    func verify(fileAt url: URL, descriptor: ModelDescriptor) -> ModelVerification { result }
}

private final class FakeDownloader: ModelDownloading, @unchecked Sendable {
    private let result: Result<ModelVerification, Error>
    private let progressSteps: [(Int64, Int64)]
    // Test-only, single-caller (never invoked concurrently by `ModelProvisioner`, which
    // `await`s one call at a time) — no lock needed for this sequential access pattern.
    private(set) var callCount = 0

    init(result: Result<ModelVerification, Error>, progressSteps: [(Int64, Int64)] = []) {
        self.result = result
        self.progressSteps = progressSteps
    }

    func download(
        descriptor: ModelDescriptor,
        into modelsDirectory: ModelsDirectory,
        onProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> ModelVerification {
        callCount += 1
        for (written, total) in progressSteps {
            onProgress(written, total)
        }
        return try result.get()
    }
}
