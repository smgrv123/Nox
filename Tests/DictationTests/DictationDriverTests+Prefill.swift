import AideCore
import LLMRuntime
import SpeechToText
import XCTest

@testable import Dictation

/// Polls `client.chatCallCount` in bounded increments until it reaches `target` or the
/// iteration budget is exhausted, then returns whatever the count settled at. Mirrors
/// `waitForActivityCount` in `+SidecarReadiness.swift`: prefill fires from an
/// unstructured `Task` in `begin(mode:)`, so nothing orders its completion relative to
/// the calling test — a fixed sleep would either flake under load or pad every run with
/// dead time.
private func waitForChatCallCount(
    _ client: RecordingLLMClient,
    atLeast target: Int,
    maxIterations: Int = 500
) async -> Int {
    var count = await client.chatCallCount
    var iterations = 0
    while count < target && iterations < maxIterations {
        try? await Task.sleep(nanoseconds: 4_000_000)
        count = await client.chatCallCount
        iterations += 1
    }
    return count
}

@MainActor
extension DictationDriverTests {

    func testPrefillFiresWhenCleanupEnabled() async {
        let llm = RecordingLLMClient()
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            cleanupEnabled: { true })

        // begin(mode:) only — never end() — so the real cleanup flow (which needs a
        // finalized transcript from Pre-Gate pass) cannot possibly have run yet. Any
        // chat call observed here can only be prefill.
        driver.begin(mode: .dictation)

        let count = await waitForChatCallCount(llm, atLeast: 1)
        XCTAssertGreaterThanOrEqual(
            count, 1,
            "prefill must fire at begin(mode:) when cleanup is enabled, before the real flow"
                + " could ever run")
    }

    func testPrefillDoesNotFireWhenCleanupDisabled() async {
        let llm = RecordingLLMClient()
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            cleanupEnabled: { false })

        driver.begin(mode: .dictation)

        // No fire expected — poll for a bounded window to give an errant fire a chance
        // to land, then assert it never did.
        let count = await waitForChatCallCount(llm, atLeast: 1, maxIterations: 50)
        XCTAssertEqual(
            count, 0,
            "prefill must not fire at begin(mode:) when cleanup is disabled")
    }

    func testPrefillPromptIsStrictPrefixOfRealCleanupPrompt() async {
        let llm = RecordingLLMClient()
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            cleanupEnabled: { true })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        // Both calls race on separate, unstructured `Task`s — prefill from begin(mode:),
        // real cleanup from Pre-Gate pass — so identify them by `maxTokens`, not by
        // array index; either may land first.
        let count = await waitForChatCallCount(llm, atLeast: 2)
        XCTAssertEqual(count, 2, "expected both a prefill call and a real cleanup call")

        let messagesHistory = await llm.chatMessagesHistory
        let paramsHistory = await llm.chatParamsHistory
        guard
            let prefillIndex = paramsHistory.firstIndex(where: { $0.maxTokens == 1 }),
            let realIndex = paramsHistory.firstIndex(where: { $0.maxTokens == 1024 })
        else {
            XCTFail("expected one call with maxTokens: 1 (prefill) and one with maxTokens: 1024 (real cleanup)")
            return
        }

        guard
            let prefillPrompt = messagesHistory[prefillIndex].first(where: { $0.role == .user })?.content,
            let realPrompt = messagesHistory[realIndex].first(where: { $0.role == .user })?.content
        else {
            XCTFail("expected a user message on both calls")
            return
        }

        // The whole feature depends on this: if the prefill prompt is not a byte-for-byte
        // strict prefix of the real cleanup prompt, llama.cpp's cache silently misses and
        // prefill becomes a wasted extra request rather than a speedup. This is a real bug
        // to report, not an assertion to loosen.
        XCTAssertTrue(
            realPrompt.hasPrefix(prefillPrompt),
            "the prefill prompt must be a strict prefix of the real cleanup prompt, or"
                + " llama.cpp's KV cache silently misses")
        XCTAssertLessThan(
            prefillPrompt.count, realPrompt.count,
            "the prefill prompt (empty transcript) must be strictly shorter than the real"
                + " cleanup prompt (non-empty transcript)")
    }

    func testPrefillFailureDoesNotBreakNormalFlow() async {
        struct InjectedError: Error {}
        let llm = MockLLMClient()
        await llm.setChatChunks(.failure(InjectedError()))
        let inserter = RecordingInserter()
        var updates: [VoiceSessionUpdate] = []
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            cleanupEnabled: { true })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        // The same throwing client backs both prefill's call and the real cleanup call.
        // Prefill swallows its own failure silently (`try?` in `firePrefill`); this proves
        // that swallow neither propagates nor hangs, and the normal raw-insert-on-failure
        // path still completes exactly as it does without prefill in the picture at all.
        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: "Inserted raw — cleanup failed.")))
    }
}
