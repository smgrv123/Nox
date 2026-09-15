import Foundation
import LLMRuntime
import XCTest

@testable import InferenceClient

/// Split out of `InferenceClientTests.swift` (which was tripping SwiftLint's
/// `type_body_length`) — the `chat_template_kwargs` / per-request thinking opt-out tests,
/// following the `Tests/DictationTests/DictationDriverTests+*.swift` split pattern. Shared
/// helpers (`makeSession`, `capturedRequestBody`, `localEndpoint`) stay on the base class.
extension InferenceClientTests {

    // MARK: - chat: per-request thinking opt-out (`chat_template_kwargs`)

    func testChatWithDisableThinkingSendsChatTemplateKwargsEnableThinkingFalse() async throws {
        var seenRequest: URLRequest?
        StubURLProtocol.handler = { request in
            seenRequest = request
            return StubURLProtocol.Response(
                statusCode: 200, body: Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.utf8))
        }

        let sut = InferenceClient(session: makeSession())
        _ = try await sut.chat(
            system: "sys", messages: [ChatMessage(role: .user, content: "hi")],
            params: SamplingParams(disableThinking: true), endpoint: localEndpoint, stream: false)

        let request = try XCTUnwrap(seenRequest)
        let requestBody = capturedRequestBody(request)
        let kwargs = try XCTUnwrap(requestBody["chat_template_kwargs"] as? [String: Any])
        XCTAssertEqual(kwargs["enable_thinking"] as? Bool, false)
    }

    func testChatWithoutDisableThinkingOmitsChatTemplateKwargsEntirely() async throws {
        var seenRequest: URLRequest?
        StubURLProtocol.handler = { request in
            seenRequest = request
            return StubURLProtocol.Response(
                statusCode: 200, body: Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.utf8))
        }

        let sut = InferenceClient(session: makeSession())
        _ = try await sut.chat(
            system: "sys", messages: [ChatMessage(role: .user, content: "hi")],
            params: .default, endpoint: localEndpoint, stream: false)

        let request = try XCTUnwrap(seenRequest)
        let requestBody = capturedRequestBody(request)
        XCTAssertNil(
            requestBody["chat_template_kwargs"],
            "the default SamplingParams must produce a request body byte-identical to before disableThinking existed")
    }

    func testRouteCompleteNeverSendsChatTemplateKwargsRegardlessOfThinkingOptOut() async throws {
        // routeComplete has no SamplingParams in its signature at all — this asserts the
        // GBNF-constrained router path can never regress into sending this key.
        var seenRequest: URLRequest?
        StubURLProtocol.handler = { request in
            seenRequest = request
            let body = """
                {"choices":[{"message":{"role":"assistant","content":"yes"},"logprobs":{"content":[]}}]}
                """
            return StubURLProtocol.Response(statusCode: 200, body: Data(body.utf8))
        }

        let sut = InferenceClient(session: makeSession())
        _ = try await sut.routeComplete(system: "s", user: "u", grammar: "g", endpoint: localEndpoint)

        let request = try XCTUnwrap(seenRequest)
        let requestBody = capturedRequestBody(request)
        XCTAssertNil(requestBody["chat_template_kwargs"])
    }
}
