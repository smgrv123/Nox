import AideCore
import SpeechToText
import XCTest

@testable import Dictation

@MainActor
final class DictationDriverTests: XCTestCase {

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

    private final class RecordingInserter: TextInserting {
        var focus = InsertionFocus(bundleID: "com.apple.TextEdit", accessibilityTrusted: true)
        var result: InsertionResult = .insertedViaAX
        private(set) var inserted: [(text: String, plan: InsertionPlan)] = []

        func resolveFocus() async -> InsertionFocus { focus }

        func insert(_ text: String, plan: InsertionPlan) async -> InsertionResult {
            inserted.append((text, plan))
            return result
        }
    }

    private let pcm = PCMBuffer(samples: [0.1, -0.1, 0.2], sampleRate: PCMBuffer.whisperSampleRate)

    private var passingTranscription: Transcription {
        Transcription(
            text: "hello world",
            language: "en",
            segments: [
                Segment(
                    text: "hello world", tStart: 0, tEnd: 1.2,
                    avgLogprob: -0.30, noSpeechProb: 0.02, compressionRatio: 1.4, tokenCount: 4)
            ])
    }

    private var silentTranscription: Transcription {
        Transcription(text: "", language: "en", segments: [])
    }

    private func makeDriver(
        engine: MockSTTEngine,
        capture: FakeCaptureBuffer,
        inserter: RecordingInserter,
        overrides: @escaping @Sendable () -> [String: AppInsertionOverride] = { [:] }
    ) -> DictationDriver {
        DictationDriver(
            engine: engine,
            capture: capture,
            preGate: SegmentPreGate(thresholds: .provisional),
            inserter: inserter,
            overrides: overrides)
    }

    func testPassInsertsRawTranscript() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let inserter = RecordingInserter()
        let driver = makeDriver(
            engine: MockSTTEngine(returning: passingTranscription),
            capture: capture,
            inserter: inserter)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        XCTAssertEqual(inserter.inserted.map(\.plan), [.axThenPaste])
        XCTAssertEqual(
            updates,
            [
                .transcript("hello world"),
                .result(VoiceSessionResult(transcript: "hello world", summary: "hello world")),
            ])
    }

    func testPasteOverrideInsertsWithPasteOnly() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let inserter = RecordingInserter()
        let driver = makeDriver(
            engine: MockSTTEngine(returning: passingTranscription),
            capture: capture,
            inserter: inserter,
            overrides: { ["com.apple.TextEdit": .paste] })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.count, 1)
        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        XCTAssertEqual(inserter.inserted.map(\.plan), [.pasteOnly])
    }

    func testInsertFailedStillDeliversTranscriptWithFailureSummary() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let inserter = RecordingInserter()
        let failureReason = "AX insert failed"
        inserter.result = .failed(reason: failureReason)
        let driver = makeDriver(
            engine: MockSTTEngine(returning: passingTranscription),
            capture: capture,
            inserter: inserter)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        XCTAssertEqual(inserter.inserted.map(\.plan), [.axThenPaste])
        XCTAssertEqual(
            updates,
            [
                .transcript("hello world"),
                .result(VoiceSessionResult(transcript: "hello world", summary: failureReason)),
            ])
    }

    func testPreGateFailDoesNotInsert() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let inserter = RecordingInserter()
        let driver = makeDriver(
            engine: MockSTTEngine(returning: silentTranscription),
            capture: capture,
            inserter: inserter)

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testCancelSuppressesInsert() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm)
        let inserter = RecordingInserter()
        let driver = makeDriver(
            engine: MockSTTEngine(returning: passingTranscription),
            capture: capture,
            inserter: inserter)

        let noUpdate = expectation(description: "no update after cancel")
        noUpdate.isInverted = true
        driver.onUpdate = { _ in noUpdate.fulfill() }

        driver.begin(mode: .dictation)
        driver.end()
        driver.cancel()

        await fulfillment(of: [noUpdate], timeout: 0.5)
        XCTAssertTrue(inserter.inserted.isEmpty)
        let discards = await capture.discardCount
        XCTAssertGreaterThanOrEqual(discards, 1)
    }

    func testMicrophoneFailureDoesNotInsert() async {
        let capture = FakeCaptureBuffer(finalizeReturns: pcm, startFails: true)
        let inserter = RecordingInserter()
        let driver = makeDriver(
            engine: MockSTTEngine(returning: passingTranscription),
            capture: capture,
            inserter: inserter)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(
            updates,
            [
                .result(
                    VoiceSessionResult(transcript: "", summary: DictationDriver.microphoneUnavailableSummary))
            ])
    }
}
