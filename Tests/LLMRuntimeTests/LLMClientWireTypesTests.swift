import XCTest

@testable import LLMRuntime

/// TDD for the `LLMClient` seam's wire types (docs/05-lld.md §3.3; plan Phase 3
/// acceptance criteria): `ChatMessage`, `SamplingParams`, `TokenLogprob`,
/// `RouterCompletion`, `ChatCompletionChunk`/`ChatCompletionStream`. Pure value-type
/// behavior only — no native process, no network, mirrors `LlmTierPolicyTests`' posture.
final class LLMClientWireTypesTests: XCTestCase {

    // MARK: - ChatMessage

    func testChatMessageStoresRoleAndContent() {
        let message = ChatMessage(role: .user, content: "hello")
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "hello")
    }

    func testChatMessageEqualityIsValueBased() {
        XCTAssertEqual(ChatMessage(role: .assistant, content: "hi"), ChatMessage(role: .assistant, content: "hi"))
        XCTAssertNotEqual(ChatMessage(role: .assistant, content: "hi"), ChatMessage(role: .user, content: "hi"))
    }

    // MARK: - SamplingParams

    func testSamplingParamsDefaultsAreConservative() {
        let defaults = SamplingParams.default
        XCTAssertEqual(defaults.temperature, 0.7)
        XCTAssertEqual(defaults.topP, 1.0)
        XCTAssertNil(defaults.maxTokens)
        XCTAssertEqual(defaults.topLogprobs, 0, "logprobs must be opt-in, not requested by default")
    }

    func testSamplingParamsCustomValuesRoundTrip() {
        let params = SamplingParams(temperature: 0.1, topP: 0.9, maxTokens: 256, topLogprobs: 3)
        XCTAssertEqual(params.temperature, 0.1)
        XCTAssertEqual(params.topP, 0.9)
        XCTAssertEqual(params.maxTokens, 256)
        XCTAssertEqual(params.topLogprobs, 3)
    }

    // MARK: - TokenLogprob

    func testTokenLogprobStoresByteRange() {
        let token = TokenLogprob(token: "Hello", logprob: -0.04, byteRange: 0..<5)
        XCTAssertEqual(token.token, "Hello")
        XCTAssertEqual(token.logprob, -0.04, accuracy: 0.0001)
        XCTAssertEqual(token.byteRange, 0..<5)
    }

    // MARK: - RouterCompletion

    func testRouterCompletionStoresRawAndAlignedLogprobs() {
        let logprobs = [
            TokenLogprob(token: "yes", logprob: -1.2, byteRange: 0..<3)
        ]
        let completion = RouterCompletion(raw: "yes", tokenLogprobs: logprobs)
        XCTAssertEqual(completion.raw, "yes")
        XCTAssertEqual(completion.tokenLogprobs, logprobs)
    }

    // MARK: - ChatCompletionChunk / ChatCompletionStream

    func testChatCompletionChunkDefaultsToEmptyLogprobs() {
        let chunk = ChatCompletionChunk(delta: "hi", isFinal: false)
        XCTAssertEqual(chunk.delta, "hi")
        XCTAssertFalse(chunk.isFinal)
        XCTAssertEqual(chunk.logprobs, [])
    }

    func testChatCompletionStreamFromChunksYieldsThemInOrder() async throws {
        let chunks = [
            ChatCompletionChunk(delta: "Hel", isFinal: false),
            ChatCompletionChunk(delta: "lo", isFinal: false),
            ChatCompletionChunk(delta: "", isFinal: true),
        ]
        let stream = ChatCompletionStream(chunks: chunks)

        var collected: [ChatCompletionChunk] = []
        for try await chunk in stream {
            collected.append(chunk)
        }
        XCTAssertEqual(collected, chunks)
    }

    func testChatCompletionStreamFromEmptyChunksFinishesImmediately() async throws {
        let stream = ChatCompletionStream(chunks: [])
        var collected: [ChatCompletionChunk] = []
        for try await chunk in stream {
            collected.append(chunk)
        }
        XCTAssertTrue(collected.isEmpty)
    }

    func testChatCompletionStreamFromAsyncThrowingStreamPropagatesThrownErrors() async {
        struct StreamError: Error, Equatable {}
        let underlying = AsyncThrowingStream<ChatCompletionChunk, Error> { continuation in
            continuation.yield(ChatCompletionChunk(delta: "partial", isFinal: false))
            continuation.finish(throwing: StreamError())
        }
        let stream = ChatCompletionStream(stream: underlying)

        var collected: [ChatCompletionChunk] = []
        do {
            for try await chunk in stream {
                collected.append(chunk)
            }
            XCTFail("expected the injected error to propagate")
        } catch is StreamError {
            XCTAssertEqual(collected, [ChatCompletionChunk(delta: "partial", isFinal: false)])
        } catch {
            XCTFail("expected StreamError, got \(error)")
        }
    }
}
