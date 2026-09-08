import AideCore
import LLMRuntime
import SpeechToText
import XCTest

@testable import Dictation

@MainActor
extension DictationDriverTests {

    func testCleanupDisabledSkipsLLM() async {
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
            cleanupEnabled: { false },
            sidecarReady: { true })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(chatCount, 0, "cleanup disabled must never call the LLM")
        XCTAssertEqual(
            updates.last,
            .result(VoiceSessionResult(transcript: "hello world", summary: "hello world")))
    }

    func testCleanupDisabledIgnoresSidecarNotReadyCopy() async {
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
            cleanupEnabled: { false },
            sidecarReady: { false })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(chatCount, 0)
        XCTAssertEqual(
            updates.last,
            .result(VoiceSessionResult(transcript: "hello world", summary: "hello world")),
            "cleanup-off must not use the sidecar-not-ready Overlay copy")
    }

    func testSidecarNotReadyInsertsRawWithExactSummary() async {
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
            sidecarReady: { false })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(chatCount, 0, "cold sidecar must not block on chat")
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: "Inserted raw — language model wasn't ready.")))
    }

    func testPrefixSelectsProfessionalInstruction() async {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription(text: "professional tone: hello world")),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() },
            tonePreset: { .asIs })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.text), ["Cleaned."])
        let messages = await llm.lastChatMessages
        let userContent = messages?.first(where: { $0.role == .user })?.content ?? ""
        XCTAssertTrue(
            userContent.contains(TonePreset.professional.instruction),
            "voice prefix must override settings.tone.defaultPreset for this utterance")
        XCTAssertTrue(userContent.contains("hello world"))
        XCTAssertFalse(
            userContent.contains("professional tone:"),
            "prefix must be stripped before cleanup")
    }
}
