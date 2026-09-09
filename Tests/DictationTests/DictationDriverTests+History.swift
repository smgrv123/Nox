import AideCore
import DangerousCommandScanner
import LLMRuntime
import SpeechToText
import XCTest

@testable import Dictation

@MainActor
extension DictationDriverTests {

    func testSuccessfulInsertAppendsHistory() async throws {
        let inserter = RecordingInserter()
        let history = RecordingHistorySink()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            appendHistory: { history.append($0) })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(history.entries.count, 1)
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.mode, "dictation")
        XCTAssertEqual(entry.transcript, "hello world")
        XCTAssertNil(entry.cleaned)
        XCTAssertFalse(entry.cleanupRan)
        XCTAssertEqual(entry.insertion, .paste)
        XCTAssertEqual(entry.destinationBundleID, "com.apple.TextEdit")

        // Latency instrumentation (P5a): no cleanup on this path, so cleanup_ms
        // stays nil — every other stage ran and must be populated and non-negative.
        let audioMs = try XCTUnwrap(entry.audioMs)
        let sttMs = try XCTUnwrap(entry.sttMs)
        let modelLoadMs = try XCTUnwrap(entry.modelLoadMs)
        let insertMs = try XCTUnwrap(entry.insertMs)
        let totalMs = try XCTUnwrap(entry.totalMs)
        XCTAssertNil(entry.cleanupMs, "cleanup was skipped — cleanup_ms must be absent, not zero")
        XCTAssertGreaterThanOrEqual(audioMs, 0)
        XCTAssertGreaterThanOrEqual(sttMs, 0)
        XCTAssertGreaterThanOrEqual(modelLoadMs, 0)
        XCTAssertGreaterThanOrEqual(insertMs, 0)
        XCTAssertGreaterThanOrEqual(
            totalMs, sttMs + insertMs,
            "total_ms spans capture-end → insert-complete, so it must cover at least stt + insert")
    }

    func testCopyEscapeAppendsCopiedHistory() async throws {
        let inserter = RecordingInserter()
        inserter.result = .failed(.pasteFailed(detail: "Couldn't insert via Accessibility or paste."))
        let history = RecordingHistorySink()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            appendHistory: { history.append($0) })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(entry.insertion, .copied)
        XCTAssertEqual(entry.transcript, "hello world")
    }

    func testCleanupSuccessRecordsCleanedHistory() async throws {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let history = RecordingHistorySink()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: RecordingInserter(),
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            appendHistory: { history.append($0) })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.transcript, "hello world")
        XCTAssertEqual(entry.cleaned, "Cleaned.")
        XCTAssertTrue(entry.cleanupRan)
        XCTAssertEqual(entry.insertion, .paste)

        // Latency instrumentation (P5a): cleanup ran, so cleanup_ms must be present
        // (not nil) and total_ms — capture-end through insert-complete — must cover it.
        let cleanupMs = try XCTUnwrap(entry.cleanupMs, "cleanup ran — cleanup_ms must be populated")
        let totalMs = try XCTUnwrap(entry.totalMs)
        XCTAssertGreaterThanOrEqual(cleanupMs, 0)
        XCTAssertGreaterThanOrEqual(totalMs, cleanupMs)
    }

    func testCleanupFailureRecordsCleanupRanHistory() async throws {
        struct InjectedError: Error {}
        let llm = MockLLMClient()
        await llm.setChatChunks(.failure(InjectedError()))
        let history = RecordingHistorySink()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: RecordingInserter(),
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            appendHistory: { history.append($0) })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(entry.transcript, "hello world")
        XCTAssertNil(entry.cleaned)
        XCTAssertTrue(entry.cleanupRan, "chat was called; cleanupRan means ran, not succeeded")
        XCTAssertEqual(entry.insertion, .paste)
    }

    func testSidecarNotReadyDoesNotRecordCleanupRan() async throws {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let history = RecordingHistorySink()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: RecordingInserter(),
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            sidecarReady: { false },
            appendHistory: { history.append($0) })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertNil(entry.cleaned)
        XCTAssertFalse(entry.cleanupRan, "sidecar never called the LLM")
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(chatCount, 0)
    }

    func testPreGateFailDoesNotAppendHistory() async {
        let history = RecordingHistorySink()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: silentTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: RecordingInserter(),
            appendHistory: { history.append($0) })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertTrue(history.entries.isEmpty)
    }

    func testCancelBeforeInsertDoesNotAppendHistory() async {
        let history = RecordingHistorySink()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: RecordingInserter(),
            appendHistory: { history.append($0) })

        let noUpdate = expectation(description: "no update after cancel")
        noUpdate.isInverted = true
        driver.onUpdate = { _ in noUpdate.fulfill() }

        driver.begin(mode: .dictation)
        driver.end()
        driver.cancel()

        await fulfillment(of: [noUpdate], timeout: 0.5)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testHardBlockDoesNotAppendHistory() async {
        let history = RecordingHistorySink()
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.apple.Terminal", accessibilityTrusted: true)
        let scanner = RecordingCommandScanner()
        scanner.verdict = .hardBlock(findings: [hardBlockFinding()])
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            scanner: scanner,
            appendHistory: { history.append($0) })

        let blocked = expectation(description: "hard-blocked")
        driver.onUpdate = { update in
            if case .hardBlocked = update { blocked.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [blocked], timeout: 2)

        XCTAssertTrue(history.entries.isEmpty)
    }

    func testApproveInsertAppendsHistory() async throws {
        let history = RecordingHistorySink()
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.apple.Terminal", accessibilityTrusted: true)
        let scanner = RecordingCommandScanner()
        scanner.verdict = .confirm(findings: [confirmFinding()])
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            scanner: scanner,
            appendHistory: { history.append($0) })

        let confirmed = expectation(description: "confirm-back")
        let executed = expectation(description: "result after approve")
        driver.onUpdate = { update in
            if case .confirmBack = update { confirmed.fulfill() }
            if case .result = update { executed.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [confirmed], timeout: 2)
        XCTAssertTrue(history.entries.isEmpty, "confirm-back must not log until Approve inserts")

        driver.approve()
        await fulfillment(of: [executed], timeout: 2)

        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(entry.transcript, "hello world")
        XCTAssertEqual(entry.insertion, .paste)
        XCTAssertEqual(entry.destinationBundleID, "com.apple.Terminal")
    }
}
