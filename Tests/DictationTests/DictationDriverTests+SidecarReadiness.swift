import AideCore
import LLMRuntime
import SpeechToText
import XCTest

@testable import Dictation

actor ActivityCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

actor WaitDeadlineCapture {
    private(set) var capturedValue: TimeInterval?

    func capture(_ value: TimeInterval) {
        capturedValue = value
    }
}

/// Polls `counter.count` in bounded increments until it reaches `target` or the
/// iteration budget is exhausted, then returns whatever the count settled at.
///
/// `noteSidecarActivity` is invoked from an unstructured `Task { ... }` at both
/// call sites in `DictationDriver`, so nothing orders its completion relative to
/// `fulfillment(of:)` resolving on the driver's own result expectation. A single
/// fixed sleep would either flake under load or pad every run with dead time;
/// this polls with a short interval and a hard iteration cap instead, so a
/// missing call surfaces as a failed assertion (count short of target) rather
/// than a hang.
private func waitForActivityCount(
    _ counter: ActivityCounter,
    atLeast target: Int,
    maxIterations: Int = 500
) async -> Int {
    var count = await counter.count
    var iterations = 0
    while count < target && iterations < maxIterations {
        try? await Task.sleep(nanoseconds: 4_000_000)
        count = await counter.count
        iterations += 1
    }
    return count
}

@MainActor
extension DictationDriverTests {

    func testKeyDownNotesSidecarActivityWhenCleanupEnabled() async {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let inserter = RecordingInserter()
        let activityCounter = ActivityCounter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            cleanupEnabled: { true },
            noteSidecarActivity: { await activityCounter.increment() })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)

        // Pin this to begin(mode:)'s own call: wait for the count to reach 1
        // *before* end() runs the rest of the flow (which would otherwise mask
        // a missing begin-side call with its own post-insert increment).
        let countAfterKeyDown = await waitForActivityCount(activityCounter, atLeast: 1)
        XCTAssertEqual(
            countAfterKeyDown, 1,
            "begin(mode:) must note sidecar activity when cleanup is enabled")

        driver.end()
        await fulfillment(of: [resolved], timeout: 2)
    }

    func testKeyDownDoesNotNoteActivityWhenCleanupDisabled() async {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let inserter = RecordingInserter()
        let activityCounter = ActivityCounter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            cleanupEnabled: { false },
            noteSidecarActivity: { await activityCounter.increment() })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        let count = await activityCounter.count
        XCTAssertEqual(
            count, 0,
            "begin(mode:) must not note sidecar activity when cleanup is disabled")
    }

    func testLaunchingSidecarCleansUpWhenTheWaitSucceeds() async {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let inserter = RecordingInserter()
        var updates: [VoiceSessionUpdate] = []
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            sidecarReadiness: { .launching },
            awaitSidecarReady: { _ in true })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        // Cleanup should run and succeed
        XCTAssertEqual(inserter.inserted, ["Cleaned."])
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(chatCount, 1, "launching sidecar that becomes ready must attempt cleanup")
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "Cleaned.",
                    summary: "Cleaned.")))
    }

    func testLaunchingSidecarInsertsRawWhenTheWaitTimesOut() async {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let inserter = RecordingInserter()
        var updates: [VoiceSessionUpdate] = []
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            sidecarReadiness: { .launching },
            awaitSidecarReady: { _ in false })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        // Should insert raw, not attempt cleanup
        XCTAssertEqual(inserter.inserted, ["hello world"])
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(chatCount, 0, "launching sidecar that times out must not attempt cleanup")
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: DictationDriver.sidecarNotReadySummary)))
    }

    func testUnavailableSidecarDoesNotWait() async {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let inserter = RecordingInserter()
        let waitDeadlineRef = WaitDeadlineCapture()
        var updates: [VoiceSessionUpdate] = []
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            sidecarReadiness: { .unavailable },
            awaitSidecarReady: { deadline in
                await waitDeadlineRef.capture(deadline)
                return false
            })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        // Should insert raw without waiting
        XCTAssertEqual(inserter.inserted, ["hello world"])
        let deadline = await waitDeadlineRef.capturedValue
        XCTAssertNil(
            deadline,
            "unavailable sidecar must not invoke awaitSidecarReady — it must not wait at all")
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(chatCount, 0, "unavailable sidecar must not attempt cleanup")
    }

    func testCompletedFlowNotesSidecarActivity() async {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let inserter = RecordingInserter()
        let activityCounter = ActivityCounter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            noteSidecarActivity: { await activityCounter.increment() })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        // The post-insert noteSidecarActivity() call is spawned in an unstructured
        // Task after gate.deliver(.result:) — the very call that fulfills `resolved`
        // above — so nothing orders it before this read. Poll deterministically
        // instead of racing a direct read against that Task.
        let count = await waitForActivityCount(activityCounter, atLeast: 2)
        XCTAssertGreaterThanOrEqual(
            count, 2,
            "activity must be noted both at begin and after insertion completes")
    }
}
