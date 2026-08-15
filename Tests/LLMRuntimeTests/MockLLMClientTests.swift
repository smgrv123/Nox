import XCTest

@testable import LLMRuntime

/// TDD for `MockLLMClient` (docs/05-lld.md §3.3; plan Phase 3 acceptance criteria:
/// "deterministic, caller-injectable completions/logprobs/stream chunks, no native
/// process involved"). Mirrors `SpeechToText`'s `MockSTTEngine` test posture.
final class MockLLMClientTests: XCTestCase {

    private let fixtureEndpoint = LLMEndpoint(
        baseURL: URL(string: "http://127.0.0.1:5555")!, model: "test-model", isLocal: true)

    // MARK: - routeComplete: canned completion, call count

    func testRouteCompleteReturnsInjectedCompletion() async throws {
        let logprobs = [TokenLogprob(token: "yes", logprob: -0.5, byteRange: 0..<3)]
        let injected = RouterCompletion(raw: "yes", tokenLogprobs: logprobs)
        let sut = MockLLMClient(routeCompletion: injected)

        let result = try await sut.routeComplete(
            system: "sys", user: "usr", grammar: "root ::= \"yes\"", endpoint: fixtureEndpoint)

        XCTAssertEqual(result, injected)
        let callCount = await sut.routeCompleteCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testRouteCompleteCallCountAccumulatesAcrossCalls() async throws {
        let sut = MockLLMClient()
        _ = try await sut.routeComplete(system: "a", user: "b", grammar: "g", endpoint: fixtureEndpoint)
        _ = try await sut.routeComplete(system: "a", user: "b", grammar: "g", endpoint: fixtureEndpoint)

        let callCount = await sut.routeCompleteCallCount
        XCTAssertEqual(callCount, 2)
    }

    func testRouteCompleteCanBeReconfiguredToThrow() async throws {
        struct InjectedError: Error, Equatable {}
        let sut = MockLLMClient()
        await sut.setRouteCompletion(.failure(InjectedError()))

        do {
            _ = try await sut.routeComplete(system: "a", user: "b", grammar: "g", endpoint: fixtureEndpoint)
            XCTFail("expected the injected error to throw")
        } catch is InjectedError {
            // expected
        }
    }

    // MARK: - chat: canned stream chunks, call count

    func testChatReturnsInjectedStreamChunksInOrder() async throws {
        let chunks = [
            ChatCompletionChunk(delta: "Hi", isFinal: false),
            ChatCompletionChunk(delta: " there", isFinal: true),
        ]
        let sut = MockLLMClient(chatChunks: chunks)

        let stream = try await sut.chat(
            system: "sys", messages: [ChatMessage(role: .user, content: "hi")],
            params: .default, endpoint: fixtureEndpoint, stream: true)

        var collected: [ChatCompletionChunk] = []
        for try await chunk in stream {
            collected.append(chunk)
        }
        XCTAssertEqual(collected, chunks)
        let callCount = await sut.chatCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testChatIgnoresTheStreamFlagAndReturnsTheSameCannedChunks() async throws {
        let chunks = [ChatCompletionChunk(delta: "same either way", isFinal: true)]
        let sut = MockLLMClient(chatChunks: chunks)

        let nonStreamed = try await sut.chat(
            system: "sys", messages: [], params: .default, endpoint: fixtureEndpoint, stream: false)
        var collected: [ChatCompletionChunk] = []
        for try await chunk in nonStreamed { collected.append(chunk) }

        XCTAssertEqual(collected, chunks)
    }

    func testChatCanBeReconfiguredToThrow() async throws {
        struct InjectedError: Error, Equatable {}
        let sut = MockLLMClient()
        await sut.setChatChunks(.failure(InjectedError()))

        do {
            _ = try await sut.chat(
                system: "sys", messages: [], params: .default, endpoint: fixtureEndpoint, stream: false)
            XCTFail("expected the injected error to throw")
        } catch is InjectedError {
            // expected
        }
    }

    // MARK: - No native process — a plain endpoint fixture is all that's needed

    func testWorksWithoutAnyLiveSidecar() async throws {
        // The whole point of MockLLMClient: constructing and calling it never touches a
        // real Process, URLSession, or network — this test's very existence is the proof.
        let sut = MockLLMClient()
        _ = try await sut.routeComplete(system: "s", user: "u", grammar: "g", endpoint: fixtureEndpoint)
        _ = try await sut.chat(system: "s", messages: [], params: .default, endpoint: fixtureEndpoint, stream: false)
    }
}
