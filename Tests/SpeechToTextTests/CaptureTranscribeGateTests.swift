import AideCore
import XCTest

@testable import SpeechToText

// MARK: - Fakes
//
// Copied rather than shared: `STTVoiceSessionDriverTests`' `FakeCaptureBuffer` lives
// in a different test target (`STTVoiceSessionTests`) and can't be imported here, and
// `MockSTTEngine` (the one fake that IS in this module) can't be made to fail, so the
// model-load / transcribe failure paths need their own scriptable conformer. Kept at
// file scope (rather than nested in the test class) to keep the class body itself
// within SwiftLint's `type_body_length`.

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

/// A scriptable `STTEngine`: `MockSTTEngine` returns its stub unconditionally and can
/// never fail, so the model-load-failure and transcribe-failure paths need this
/// conformer instead. Also records what it was called with, for the
/// `makeInitialPrompt` seam assertion.
private actor ScriptedSTTEngine: STTEngine {
    private let transcription: Transcription
    private let ensureLoadedError: Error?
    private let transcribeError: Error?

    private(set) var transcribeCallCount = 0
    /// Double-optional: outer `nil` means "never called"; `.some(nil)` means "called
    /// with no bias prompt" — distinguishes the two for the default-prompt assertion.
    private(set) var lastInitialPrompt: String??

    init(
        returning transcription: Transcription,
        ensureLoadedError: Error? = nil,
        transcribeError: Error? = nil
    ) {
        self.transcription = transcription
        self.ensureLoadedError = ensureLoadedError
        self.transcribeError = transcribeError
    }

    func ensureLoaded() async throws {
        if let ensureLoadedError { throw ensureLoadedError }
    }

    func transcribe(
        _ pcm: PCMBuffer, language: LanguageHint, initialPrompt: String?
    ) async throws -> Transcription {
        transcribeCallCount += 1
        lastInitialPrompt = .some(initialPrompt)
        if let transcribeError { throw transcribeError }
        return transcription
    }
}

private enum ScriptedError: Error { case boom }

/// Direct, isolated coverage for `CaptureTranscribeGate` — P5a's extraction of the
/// capture → transcribe → Pre-Gate front half shared by every real `VoiceSessionDriver`
/// (`STTVoiceSessionDriver`, `Dictation.DictationDriver`). Previously exercised only
/// incidentally through those two drivers' own suites; this pins the gate's own contract
/// directly (CLAUDE.md "Deep modules, tested in isolation" / "TDD for deep modules") —
/// the generation guard that makes cancellation safe above all, since that's the one
/// piece every real driver depends on the gate to get right.
///
/// `@MainActor` so `begin`/`end`/`cancel` run on the actor the gate delivers `onUpdate`/
/// `onPass` on (LLD §10) and its internal `Task { @MainActor }` work interleaves here —
/// mirrors `STTVoiceSessionDriverTests`.
@MainActor
final class CaptureTranscribeGateTests: XCTestCase {

    // MARK: - Fixtures

    private let pcm = PCMBuffer(samples: [0.1, -0.1, 0.2], sampleRate: PCMBuffer.whisperSampleRate)

    /// A clean utterance that clears the Pre-Gate even in strict command mode.
    private static func passingTranscription(text: String = "open my calendar") -> Transcription {
        Transcription(
            text: text,
            language: "en",
            segments: [
                Segment(
                    text: text, tStart: 0, tEnd: 2,
                    avgLogprob: -0.30, noSpeechProb: 0.02, compressionRatio: 1.4, tokenCount: 6)
            ])
    }

    /// Silence: no segments ⇒ the Pre-Gate returns `fail(.noSpeech)`.
    private static func silentTranscription() -> Transcription {
        Transcription(text: "", language: "en", segments: [])
    }

    private func makeGate(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        makeInitialPrompt: @escaping @Sendable () async -> String? = { nil }
    ) -> CaptureTranscribeGate {
        CaptureTranscribeGate(
            engine: engine,
            capture: capture,
            preGate: SegmentPreGate(thresholds: .provisional),
            makeInitialPrompt: makeInitialPrompt)
    }

    // MARK: - Generation guard / cancellation (the load-bearing behaviour)

    func testCancelAfterEndPreventsStaleResultFromBeingDelivered() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let engine = ScriptedSTTEngine(returning: Self.passingTranscription())
        let gate = makeGate(engine: engine, capture: capture)

        let noUpdate = expectation(description: "no update after cancel")
        noUpdate.isInverted = true
        let noPass = expectation(description: "no onPass after cancel")
        noPass.isInverted = true
        gate.onUpdate = { _ in noUpdate.fulfill() }
        gate.onPass = { _, _, _ in noPass.fulfill() }

        gate.begin(mode: .command)
        gate.end()
        gate.cancel()  // a newer press interrupts before the async decode can deliver

        await fulfillment(of: [noUpdate, noPass], timeout: 0.5)

        let discards = await capture.discardCount
        XCTAssertGreaterThanOrEqual(
            discards, 1, "a cancelled capture is discarded, not finalized into a result")
    }

    /// `begin()` itself is the other half of "a new press cancels the prior" (LLD §10):
    /// no explicit `cancel()` is ever called here — the second `begin()` alone must bump
    /// the generation far enough that the first session's still-in-flight `end()` never
    /// delivers, even though nothing told it to stop.
    func testANewerBeginInvalidatesAPriorInFlightSessionWithoutAnExplicitCancel() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let engine = ScriptedSTTEngine(returning: Self.passingTranscription())
        let gate = makeGate(engine: engine, capture: capture)

        var passCalls: [(text: String, generation: Int)] = []
        let resolved = expectation(description: "the second, current session resolves")
        gate.onPass = { text, generation, _ in
            passCalls.append((text, generation))
            resolved.fulfill()
        }

        gate.begin(mode: .command)
        gate.end()  // session 1 — nothing has awaited yet, so this is still purely queued
        gate.begin(mode: .command)  // a newer press supersedes it before it can resolve
        gate.end()  // session 2

        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(passCalls.count, 1, "the superseded first session must never call onPass")
        XCTAssertEqual(passCalls.first?.generation, 2, "only the second, current session resolves")
    }

    // MARK: - Microphone-open failure

    func testMicrophoneOpenFailureDeliversDegradedResultWithoutTranscribing() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm, startFails: true)
        let engine = ScriptedSTTEngine(returning: Self.passingTranscription())
        let gate = makeGate(engine: engine, capture: capture)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        gate.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }
        gate.onPass = { _, _, _ in XCTFail("onPass must not fire when the mic never opened") }

        gate.begin(mode: .command)
        gate.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(
            updates,
            [
                .result(
                    VoiceSessionResult(
                        transcript: "", summary: CaptureTranscribeGate.microphoneUnavailableSummary))
            ],
            "a mic that won't open fails safe with a clear human-readable state")

        let transcribeCalls = await engine.transcribeCallCount
        XCTAssertEqual(transcribeCalls, 0, "a mic that never opened must never reach transcription")
    }

    // MARK: - Pre-Gate fail → re-ask

    func testPreGateFailDeliversReAskResultAndNeverCallsOnPass() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let engine = ScriptedSTTEngine(returning: Self.silentTranscription())
        let gate = makeGate(engine: engine, capture: capture)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        gate.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }
        gate.onPass = { _, _, _ in XCTFail("onPass must not fire on a Pre-Gate fail") }

        gate.begin(mode: .command)
        gate.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(
            updates,
            [.result(VoiceSessionResult(transcript: "", summary: CaptureTranscribeGate.reAskSummary))],
            "a silent/garbled capture surfaces the honest re-ask")
    }

    // MARK: - Pre-Gate pass → onPass, and only onPass

    func testPreGatePassInvokesOnPassAndDeliversNoUpdateOfItsOwn() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let engine = ScriptedSTTEngine(returning: Self.passingTranscription(text: "open my calendar"))
        let gate = makeGate(engine: engine, capture: capture)

        var updates: [VoiceSessionUpdate] = []
        gate.onUpdate = { updates.append($0) }

        var passedText: String?
        var passedGeneration: Int?
        let passed = expectation(description: "onPass fires")
        gate.onPass = { text, generation, _ in
            passedText = text
            passedGeneration = generation
            passed.fulfill()
        }

        gate.begin(mode: .command)
        gate.end()
        await fulfillment(of: [passed], timeout: 2)

        XCTAssertEqual(passedText, "open my calendar")
        XCTAssertEqual(
            passedGeneration, 1,
            "the generation stamped at begin() is handed back so a driver's own tail can re-check it")
        XCTAssertTrue(
            updates.isEmpty,
            "on pass the gate calls onPass and stops — a driver's own divergent tail is responsible "
                + "for any .transcript/.result of its own")
    }

    // MARK: - Model-load / transcribe failure → "speech model isn't ready"

    func testModelLoadFailureDeliversModelNotReadyResultWithoutTranscribing() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let engine = ScriptedSTTEngine(
            returning: Self.silentTranscription(), ensureLoadedError: ScriptedError.boom)
        let gate = makeGate(engine: engine, capture: capture)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        gate.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }
        gate.onPass = { _, _, _ in XCTFail("onPass must not fire when the model can't load") }

        gate.begin(mode: .command)
        gate.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(
            updates,
            [.result(VoiceSessionResult(transcript: "", summary: CaptureTranscribeGate.modelNotReadySummary))],
            "a model that won't load fails safe with a clear human-readable state (User Story 19)")

        let transcribeCalls = await engine.transcribeCallCount
        XCTAssertEqual(transcribeCalls, 0, "ensureLoaded fails before transcription is ever attempted")
    }

    func testTranscribeFailureDeliversModelNotReadyResult() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let engine = ScriptedSTTEngine(
            returning: Self.passingTranscription(), transcribeError: ScriptedError.boom)
        let gate = makeGate(engine: engine, capture: capture)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        gate.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }
        gate.onPass = { _, _, _ in XCTFail("onPass must not fire when transcription throws") }

        gate.begin(mode: .command)
        gate.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(
            updates,
            [.result(VoiceSessionResult(transcript: "", summary: CaptureTranscribeGate.modelNotReadySummary))],
            "a transcription failure fails safe with the same degraded copy as a model-load failure")
    }

    // MARK: - Timings

    func testTimingsAudioMsIsDerivedFromSampleCountAndSampleRate() async {
        // 32,000 samples @ 16kHz = exactly 2000ms of audio.
        let twoSecondPCM = PCMBuffer(
            samples: Array(repeating: Float(0.1), count: 32_000), sampleRate: 16_000)
        let capture = FakeCaptureBuffer(finalizeReturns: twoSecondPCM)
        let engine = ScriptedSTTEngine(returning: Self.passingTranscription())
        let gate = makeGate(engine: engine, capture: capture)

        var timings: CaptureTranscribeGate.Timings?
        let passed = expectation(description: "onPass fires")
        gate.onPass = { _, _, captured in
            timings = captured
            passed.fulfill()
        }

        gate.begin(mode: .command)
        gate.end()
        await fulfillment(of: [passed], timeout: 2)

        XCTAssertEqual(timings?.audioMs, 2000, "audioMs is sample count ÷ sample rate, not decode latency")
    }

    func testTimingsSttAndModelLoadMsAreNonNegativeAndCaptureEndedAtPrecedesNow() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let engine = ScriptedSTTEngine(returning: Self.passingTranscription())
        let gate = makeGate(engine: engine, capture: capture)

        var timings: CaptureTranscribeGate.Timings?
        let passed = expectation(description: "onPass fires")
        gate.onPass = { _, _, captured in
            timings = captured
            passed.fulfill()
        }

        gate.begin(mode: .command)
        gate.end()
        await fulfillment(of: [passed], timeout: 2)

        guard let timings else { return XCTFail("onPass never delivered timings") }
        XCTAssertGreaterThanOrEqual(timings.sttMs, 0)
        XCTAssertGreaterThanOrEqual(timings.modelLoadMs, 0)
        XCTAssertLessThanOrEqual(
            timings.captureEndedAt, ContinuousClock.now,
            "captureEndedAt is stamped when the mic finalized, before decode began — it can never be "
                + "later than the current instant")
    }

    // MARK: - makeInitialPrompt (P5b seam)

    func testMakeInitialPromptIsAwaitedAndPassedToTranscribe() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let engine = ScriptedSTTEngine(returning: Self.passingTranscription())
        let gate = makeGate(
            engine: engine, capture: capture,
            makeInitialPrompt: {
                await Task.yield()  // prove it's genuinely awaited, not just called synchronously
                return "user's personal dictionary bias"
            })

        let passed = expectation(description: "onPass fires")
        gate.onPass = { _, _, _ in passed.fulfill() }

        gate.begin(mode: .command)
        gate.end()
        await fulfillment(of: [passed], timeout: 2)

        let recordedPrompt = await engine.lastInitialPrompt
        XCTAssertEqual(recordedPrompt, .some("user's personal dictionary bias"))
    }

    /// `STTVoiceSessionDriver` leaves this seam at its default — mirrors the doc comment
    /// on `CaptureTranscribeGate.makeInitialPrompt`.
    func testDefaultMakeInitialPromptPassesNilToTranscribe() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let engine = ScriptedSTTEngine(returning: Self.passingTranscription())
        let gate = makeGate(engine: engine, capture: capture)  // default makeInitialPrompt = { nil }

        let passed = expectation(description: "onPass fires")
        gate.onPass = { _, _, _ in passed.fulfill() }

        gate.begin(mode: .command)
        gate.end()
        await fulfillment(of: [passed], timeout: 2)

        let recordedPrompt = await engine.lastInitialPrompt
        XCTAssertEqual(
            recordedPrompt, .some(nil), "no bias prompt is the default — never a stray non-nil value")
    }
}
