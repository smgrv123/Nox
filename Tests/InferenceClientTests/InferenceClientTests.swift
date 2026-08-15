import Foundation
import LLMRuntime
import XCTest

@testable import InferenceClient

/// Headless tests for the real `LLMClient` conformer (plan Phase 3 acceptance criteria).
/// Exercised against `StubURLProtocol` — an in-process fake HTTP server standing in for
/// the loopback Sidecar — never a real `llama-server` process or real network (mirrors
/// `ModelDownloaderTests`'s posture for `ModelDownloader`). The exact wire shapes
/// asserted against here (field names, the SSE `data:`/`[DONE]` framing, the
/// `logprobs.content[].bytes` field) were captured from the real bundled `llama-server`
/// binary (`b10332`) during this phase's development — see `ChatCompletionWireTypes.swift`.
final class InferenceClientTests: XCTestCase {

    private let localEndpoint = LLMEndpoint(
        baseURL: URL(string: "http://127.0.0.1:5555")!, model: "qwen-test.gguf", isLocal: true)

    override func setUpWithError() throws {
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func capturedRequestBody(_ request: URLRequest) -> [String: Any] {
        guard let body = request.httpBodyStreamData() ?? request.httpBody,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return [:] }
        return json
    }

    // MARK: - routeComplete: grammar passthrough, aligned logprobs

    func testRouteCompletePassesGrammarThroughUnmodifiedAndRequestsLogprobs() async throws {
        var seenRequest: URLRequest?
        StubURLProtocol.handler = { request in
            seenRequest = request
            let body = """
                {"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"yes"},
                "logprobs":{"content":[{"id":9693,"token":"yes","bytes":[121,101,115],"logprob":-0.5}]}}]}
                """
            return StubURLProtocol.Response(statusCode: 200, body: Data(body.utf8))
        }

        let sut = InferenceClient(session: makeSession())
        let grammar = "root ::= \"yes\" | \"no\""
        let result = try await sut.routeComplete(
            system: "You are a router.", user: "Is the sky blue?", grammar: grammar, endpoint: localEndpoint)

        XCTAssertEqual(result.raw, "yes")
        XCTAssertEqual(result.tokenLogprobs, [TokenLogprob(token: "yes", logprob: -0.5, byteRange: 0..<3)])

        let request = try XCTUnwrap(seenRequest)
        let requestBody = capturedRequestBody(request)
        XCTAssertEqual(
            requestBody["grammar"] as? String, grammar, "the supplied GBNF grammar must pass through unmodified")
        XCTAssertEqual(requestBody["stream"] as? Bool, false)
        XCTAssertEqual(requestBody["logprobs"] as? Bool, true)
    }

    func testRouteCompletePassesAnEmptyGrammarThroughAsAnEmptyStringNotOmitted() async throws {
        var seenRequest: URLRequest?
        StubURLProtocol.handler = { request in
            seenRequest = request
            let body = """
                {"choices":[{"message":{"role":"assistant","content":""},"logprobs":{"content":[]}}]}
                """
            return StubURLProtocol.Response(statusCode: 200, body: Data(body.utf8))
        }

        let sut = InferenceClient(session: makeSession())
        _ = try await sut.routeComplete(system: "s", user: "u", grammar: "", endpoint: localEndpoint)

        let request = try XCTUnwrap(seenRequest)
        let requestBody = capturedRequestBody(request)
        XCTAssertNotNil(requestBody["grammar"], "an empty grammar must still be sent, not dropped from the payload")
        XCTAssertEqual(requestBody["grammar"] as? String, "")
    }

    func testRouteCompleteWithMultipleTokensAlignsByteRangesInGenerationOrder() async throws {
        StubURLProtocol.handler = { _ in
            let body = """
                {"choices":[{"message":{"role":"assistant","content":"Hello!"},"logprobs":{"content":[
                {"token":"Hello","bytes":[72,101,108,108,111],"logprob":-0.04},
                {"token":"!","bytes":[33],"logprob":-0.08}
                ]}}]}
                """
            return StubURLProtocol.Response(statusCode: 200, body: Data(body.utf8))
        }

        let sut = InferenceClient(session: makeSession())
        let result = try await sut.routeComplete(system: "s", user: "u", grammar: "g", endpoint: localEndpoint)

        XCTAssertEqual(result.raw, "Hello!")
        XCTAssertEqual(
            result.tokenLogprobs,
            [
                TokenLogprob(token: "Hello", logprob: -0.04, byteRange: 0..<5),
                TokenLogprob(token: "!", logprob: -0.08, byteRange: 5..<6),
            ])
    }

    // MARK: - chat: non-streamed → single final chunk

    func testChatNonStreamedReturnsOneFinalChunkWithAlignedLogprobs() async throws {
        var seenRequest: URLRequest?
        StubURLProtocol.handler = { request in
            seenRequest = request
            let body = """
                {"choices":[{"message":{"role":"assistant","content":"Hi there"},"logprobs":{"content":[
                {"token":"Hi","bytes":[72,105],"logprob":-0.1},
                {"token":" there","bytes":[32,116,104,101,114,101],"logprob":-0.2}
                ]}}]}
                """
            return StubURLProtocol.Response(statusCode: 200, body: Data(body.utf8))
        }

        let sut = InferenceClient(session: makeSession())
        let stream = try await sut.chat(
            system: "sys", messages: [ChatMessage(role: .user, content: "hi")],
            params: SamplingParams(topLogprobs: 2), endpoint: localEndpoint, stream: false)

        var collected: [ChatCompletionChunk] = []
        for try await chunk in stream { collected.append(chunk) }

        XCTAssertEqual(collected.count, 1, "a non-streamed chat call must still yield exactly one chunk")
        let chunk = try XCTUnwrap(collected.first)
        XCTAssertEqual(chunk.delta, "Hi there")
        XCTAssertTrue(chunk.isFinal)
        XCTAssertEqual(
            chunk.logprobs,
            [
                TokenLogprob(token: "Hi", logprob: -0.1, byteRange: 0..<2),
                TokenLogprob(token: " there", logprob: -0.2, byteRange: 2..<8),
            ])

        let request = try XCTUnwrap(seenRequest)
        let requestBody = capturedRequestBody(request)
        XCTAssertEqual(requestBody["stream"] as? Bool, false)
        XCTAssertNil(requestBody["grammar"], "chat must never send a grammar")
        XCTAssertEqual(requestBody["top_logprobs"] as? Int, 2)
    }

    // MARK: - chat: streamed → multiple chunks, cumulative byte ranges, [DONE] terminates

    func testChatStreamedYieldsMultipleChunksWithCumulativeByteRangesAndStops() async throws {
        var seenRequest: URLRequest?
        StubURLProtocol.handler = { request in
            seenRequest = request
            // These SSE fixture lines mirror the real llama-server wire output captured
            // during this phase's development verbatim (one JSON object per physical
            // line is the SSE framing itself, not a style choice) — long lines here are
            // load-bearing fidelity, not something to wrap.
            // swiftlint:disable line_length
            let sse = """
                data: {"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}]}

                data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"Sure"},"logprobs":{"content":[{"token":"Sure","bytes":[83,117,114,101],"logprob":-0.8}]}}]}

                data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"!"},"logprobs":{"content":[{"token":"!","bytes":[33],"logprob":-0.5}]}}]}

                data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}

                data: [DONE]

                """
            // swiftlint:enable line_length
            // Deliver in several arbitrary-sized pieces (not aligned to SSE event
            // boundaries) so `.lines` genuinely has to reassemble lines across chunk
            // boundaries — the real streaming path, not one instantaneous burst.
            let bytes = Array(sse.utf8)
            let pieceSize = 40
            var pieces: [Data] = []
            var start = 0
            while start < bytes.count {
                let end = min(start + pieceSize, bytes.count)
                pieces.append(Data(bytes[start..<end]))
                start = end
            }
            return StubURLProtocol.Response(statusCode: 200, chunks: pieces)
        }

        let sut = InferenceClient(session: makeSession())
        let stream = try await sut.chat(
            system: "sys", messages: [ChatMessage(role: .user, content: "count")],
            params: SamplingParams(topLogprobs: 1), endpoint: localEndpoint, stream: true)

        var collected: [ChatCompletionChunk] = []
        for try await chunk in stream { collected.append(chunk) }

        // The role-only announcement chunk (no content, no logprobs, not final) must be
        // suppressed — three real chunks remain: "Sure", "!", and the terminal marker.
        XCTAssertEqual(collected.count, 3)
        XCTAssertEqual(collected[0].delta, "Sure")
        XCTAssertFalse(collected[0].isFinal)
        XCTAssertEqual(collected[0].logprobs, [TokenLogprob(token: "Sure", logprob: -0.8, byteRange: 0..<4)])

        XCTAssertEqual(collected[1].delta, "!")
        XCTAssertFalse(collected[1].isFinal)
        XCTAssertEqual(
            collected[1].logprobs, [TokenLogprob(token: "!", logprob: -0.5, byteRange: 4..<5)],
            "byte ranges must be cumulative across chunks, not reset per chunk")

        XCTAssertEqual(collected[2].delta, "")
        XCTAssertTrue(collected[2].isFinal, "the finish_reason chunk must surface as the terminal, isFinal chunk")

        let request = try XCTUnwrap(seenRequest)
        let requestBody = capturedRequestBody(request)
        XCTAssertEqual(requestBody["stream"] as? Bool, true)
    }

    // MARK: - Error paths

    func testUnexpectedStatusCodeThrowsUnexpectedResponse() async throws {
        StubURLProtocol.handler = { _ in StubURLProtocol.Response(statusCode: 500, body: Data("oops".utf8)) }

        let sut = InferenceClient(session: makeSession())
        do {
            _ = try await sut.routeComplete(system: "s", user: "u", grammar: "g", endpoint: localEndpoint)
            XCTFail("expected a 500 to throw")
        } catch InferenceClientError.unexpectedResponse(let statusCode) {
            XCTAssertEqual(statusCode, 500)
        }
    }

    func testEmptyChoicesArrayThrowsEmptyCompletionRatherThanSilentlySucceeding() async throws {
        StubURLProtocol.handler = { _ in StubURLProtocol.Response(statusCode: 200, body: Data(#"{"choices":[]}"#.utf8))
        }

        let sut = InferenceClient(session: makeSession())
        do {
            _ = try await sut.routeComplete(system: "s", user: "u", grammar: "g", endpoint: localEndpoint)
            XCTFail("expected an empty choices array to throw, never silently report an empty completion")
        } catch InferenceClientError.emptyCompletion {
            // expected
        }
    }

    // MARK: - Cloud-target shape compiles/type-checks and behaves correctly (never exercised against a real host)

    func testCloudEndpointSendsBearerAuthorizationFromApiKeyRef() async throws {
        var seenRequest: URLRequest?
        StubURLProtocol.handler = { request in
            seenRequest = request
            return StubURLProtocol.Response(
                statusCode: 200, body: Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.utf8))
        }

        // A cloud-shaped endpoint (isLocal: false, a non-nil apiKeyRef) — constructed
        // only against the local StubURLProtocol fixture here, never a real cloud host
        // (that consent-gated wiring is P6). Proves the code path compiles/type-checks
        // and behaves correctly without ever making a real outbound cloud call.
        let cloudEndpoint = LLMEndpoint(
            baseURL: URL(string: "https://example-cloud.invalid")!,
            apiKeyRef: "sk-test-123", model: "gpt-cloud", isLocal: false)

        let sut = InferenceClient(session: makeSession())
        _ = try await sut.chat(
            system: "s", messages: [], params: .default, endpoint: cloudEndpoint, stream: false)

        let request = try XCTUnwrap(seenRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
    }

    func testLocalEndpointWithNoApiKeyRefOmitsAuthorizationHeader() async throws {
        var seenRequest: URLRequest?
        StubURLProtocol.handler = { request in
            seenRequest = request
            return StubURLProtocol.Response(
                statusCode: 200, body: Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.utf8))
        }

        let sut = InferenceClient(session: makeSession())
        _ = try await sut.chat(system: "s", messages: [], params: .default, endpoint: localEndpoint, stream: false)

        let request = try XCTUnwrap(seenRequest)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(localEndpoint.isLocal, true)
    }
}

extension URLRequest {
    /// `URLProtocol`'s captured `request` sometimes carries the body as an
    /// `httpBodyStream` rather than `httpBody` depending on how the session normalizes
    /// it; this reads either so assertions never flake on which one was populated.
    fileprivate func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
