import AideCore
import SpeechToText
import XCTest

@testable import STTVoiceSession

/// The real driver's orchestration, tested headlessly on the main actor (plan Phase 3):
/// a fake `AudioCaptureBuffer` + `MockSTTEngine` + the **real** `SegmentPreGate` drive the
/// three behaviours the seam promises — pass → `.transcript` then `.result`, Pre-Gate
/// `fail` → the re-ask `.result`, and `cancel` → suppressed. No mic, no native binary.
///
/// `@MainActor` so `begin`/`end`/`cancel` run on the actor the seam delivers `onUpdate`
/// on (LLD §10) and the driver's internal `Task { @MainActor }` work interleaves here.
@MainActor
final class STTVoiceSessionDriverTests: XCTestCase {

    // MARK: - Fakes

    /// A scriptable `AudioCaptureBuffer`: records the lifecycle and hands `finalize` a
    /// caller-supplied utterance (or `start` throws when `startFails` is set — the
    /// mic-denied path). No AVFoundation — the AVAudioEngine tap is out of this suite.
    private actor FakeCaptureBuffer: AudioCaptureBuffer {
        enum CaptureError: Error { case micDenied }

        private let utterance: PCMBuffer
        private let startFails: Bool
        private(set) var startCount = 0
        private(set) var finalizeCount = 0
        private(set) var discardCount = 0

        init(finalizeReturns utterance: PCMBuffer, startFails: Bool = false) {
            self.utterance = utterance
            self.startFails = startFails
        }

        func start() async throws {
            startCount += 1
            if startFails { throw CaptureError.micDenied }
        }
        func append(_ frames: PCMBuffer) async {}
        func finalize() async -> PCMBuffer {
            finalizeCount += 1
            return utterance
        }
        func discard() async { discardCount += 1 }
    }

    // MARK: - Fixtures

    private let pcm = PCMBuffer(samples: [0.1, -0.1, 0.2], sampleRate: PCMBuffer.whisperSampleRate)

    /// A clean utterance that clears the Pre-Gate even in strict command mode.
    private var passingTranscription: Transcription {
        Transcription(
            text: "open my calendar",
            language: "en",
            segments: [
                Segment(
                    text: "open my calendar", tStart: 0, tEnd: 2,
                    avgLogprob: -0.30, noSpeechProb: 0.02, compressionRatio: 1.4, tokenCount: 6)
            ])
    }

    /// Silence: no segments ⇒ the Pre-Gate returns `fail(.noSpeech)`.
    private var silentTranscription: Transcription {
        Transcription(text: "", language: "en", segments: [])
    }

    private func makeDriver(
        engine: MockSTTEngine,
        capture: FakeCaptureBuffer
    ) -> STTVoiceSessionDriver {
        STTVoiceSessionDriver(
            engine: engine,
            capture: capture,
            preGate: SegmentPreGate(thresholds: .provisional))
    }

    // MARK: - Pass → transcript then result

    func testPassEmitsTranscriptThenPlaceholderResult() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let driver = makeDriver(engine: MockSTTEngine(returning: passingTranscription), capture: capture)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .command)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(
            updates,
            [
                .transcript("open my calendar"),
                .result(VoiceSessionResult(transcript: "open my calendar", summary: "open my calendar")),
            ],
            "a passing capture emits the real transcript, then the placeholder result")

        let starts = await capture.startCount
        let finalizes = await capture.finalizeCount
        XCTAssertEqual(starts, 1, "the mic opens exactly once, on the hold")
        XCTAssertEqual(finalizes, 1, "and closes exactly once, on release")
    }

    // MARK: - Pre-Gate fail → re-ask

    func testPreGateFailEmitsReAskResultAndNoTranscript() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let driver = makeDriver(engine: MockSTTEngine(returning: silentTranscription), capture: capture)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .command)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(
            updates,
            [.result(VoiceSessionResult(transcript: "", summary: STTVoiceSessionDriver.reAskSummary))],
            "a silent/garbled capture surfaces the honest re-ask — no transcript first")
    }

    // MARK: - Cancel → suppressed

    func testCancelSuppressesAnyPendingUpdate() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let driver = makeDriver(engine: MockSTTEngine(returning: passingTranscription), capture: capture)

        let noUpdate = expectation(description: "no update after cancel")
        noUpdate.isInverted = true
        driver.onUpdate = { _ in noUpdate.fulfill() }

        driver.begin(mode: .command)
        driver.end()
        driver.cancel()  // a newer press interrupts before the async decode can deliver

        await fulfillment(of: [noUpdate], timeout: 0.5)

        let discards = await capture.discardCount
        XCTAssertGreaterThanOrEqual(discards, 1, "a cancelled capture is discarded, not finalized into a result")
    }

    // MARK: - Graceful degradation

    func testMicUnavailableSurfacesADegradedResultNotACrash() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm, startFails: true)
        let driver = makeDriver(engine: MockSTTEngine(returning: passingTranscription), capture: capture)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .command)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(
            updates,
            [.result(VoiceSessionResult(transcript: "", summary: STTVoiceSessionDriver.microphoneUnavailableSummary))],
            "a mic that won't open fails safe with a clear human-readable state")
    }

    // MARK: - Repeated captures stay sane (warm reuse)

    func testBackToBackCapturesEachResolve() async {
        let engine = MockSTTEngine(returning: passingTranscription)
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let driver = makeDriver(engine: engine, capture: capture)

        for _ in 0..<2 {
            let resolved = expectation(description: "result delivered")
            driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }
            driver.begin(mode: .command)
            driver.end()
            await fulfillment(of: [resolved], timeout: 2)
        }

        let starts = await capture.startCount
        let finalizes = await capture.finalizeCount
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(finalizes, 2)
        let loads = await engine.ensureLoadedCallCount
        XCTAssertGreaterThanOrEqual(loads, 1, "the model is loaded lazily and reused (kept warm) across captures")
    }
}
