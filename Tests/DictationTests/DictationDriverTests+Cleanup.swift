import AideCore
import LLMRuntime
import SpeechToText
import XCTest

@testable import Dictation

@MainActor
extension DictationDriverTests {

    func testCleanupInsertsSanitizedText() async {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted, ["Cleaned."])
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(chatCount, 1)
        let params = await llm.lastSamplingParams
        XCTAssertEqual(params?.temperature, 0.2)
        XCTAssertEqual(
            params?.disableThinking, true,
            "dictation cleanup must opt out of model-side reasoning — it's a short free-form"
                + " completion where Qwen3's default thinking mode dwarfs the answer in latency")
    }

    func testCleanupFailureInsertsRaw() async {
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
            resolveEndpoint: { dictationTestEndpoint() })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

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

    func testResolveEndpointFailureInsertsRaw() async {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let inserter = RecordingInserter()
        var updates: [VoiceSessionUpdate] = []
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { throw DictationTestError.endpointUnavailable })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted, ["hello world"])
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(chatCount, 0)
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: "hello world")))
    }

    func testNonLocalEndpointSkipsCleanup() async {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint(isLocal: false) })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted, ["hello world"])
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(chatCount, 0, "dictation must never implicitly offload to a non-local endpoint")
    }
}
