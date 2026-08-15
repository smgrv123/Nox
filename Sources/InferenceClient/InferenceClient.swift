import Foundation
import LLMRuntime

/// Why an `InferenceClient` call failed at the transport/wire level (as opposed to a
/// plain `URLSession` error, which propagates unmodified). Kept narrow and typed, same
/// posture as `ModelDownloaderError`/`LlamaServerProcessSourceError`.
public enum InferenceClientError: Error, Equatable, Sendable {
    case unexpectedResponse(statusCode: Int?)
    /// The Sidecar answered 2xx with a `choices` array that had nothing in it — never
    /// silently treated as an empty-string completion.
    case emptyCompletion
}

/// The real `LLMClient` conformer (docs/05-lld.md §3.3; plan Phase 3; User Stories 1-5,
/// 19, 20) — a `URLSession`-based OpenAI-compatible HTTP client. See this module's
/// product comment in `Package.swift` for why it lives in its own module rather than
/// `App/`: its request-building/JSON-and-SSE-parsing logic is genuinely unit-testable
/// headlessly against a `URLProtocol` stub (`InferenceClientTests`), mirroring
/// `ModelDownloader`'s precedent — only the "point this at the real Sidecar's endpoint"
/// wiring is effectful, and that's just constructing an `LLMEndpoint` from
/// `SidecarManager.endpoint`, which needs no test double of its own.
///
/// Targets the local Sidecar's `LLMEndpoint` (`isLocal: true`) today. The exact same
/// client also type-checks against a cloud-shaped `LLMEndpoint` (`isLocal: false`,
/// non-nil `apiKeyRef`) — `apiKeyRef` becomes a Bearer token — but P2b never constructs
/// or exercises one against a real cloud host; that consent-gated wiring is P6.
public final class InferenceClient: LLMClient, @unchecked Sendable {

    /// `routeComplete` has no `SamplingParams` in its LLD signature — these are its own
    /// conservative, provisional defaults (PRD "Out of Scope": final calibration is a
    /// later concern). Temperature 0 for reproducible routing decisions; a generous but
    /// bounded token cap so a malformed grammar can't hang a request forever.
    private static let routeCompleteTemperature: Double = 0
    private static let routeCompleteMaxTokens = 256
    private static let routeCompleteTopLogprobs = 1

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - LLMClient

    public func routeComplete(
        system: String,
        user: String,
        grammar: String,
        endpoint: LLMEndpoint
    ) async throws -> RouterCompletion {
        let body = ChatCompletionRequestBody(
            model: endpoint.model,
            messages: [
                .init(role: ChatMessage.Role.system.rawValue, content: system),
                .init(role: ChatMessage.Role.user.rawValue, content: user),
            ],
            temperature: Self.routeCompleteTemperature,
            topP: 1,
            maxTokens: Self.routeCompleteMaxTokens,
            stream: false,
            logprobs: true,
            topLogprobs: Self.routeCompleteTopLogprobs,
            // Passthrough, unmodified — even an empty grammar string is still sent
            // explicitly rather than the key being omitted (see the DTO's doc comment).
            grammar: grammar)

        let request = try makeRequest(endpoint: endpoint, body: body)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)

        let decoded = try JSONDecoder().decode(ChatCompletionResponseBody.self, from: data)
        guard let choice = decoded.choices.first else {
            throw InferenceClientError.emptyCompletion
        }
        let raw = choice.message.content ?? ""
        let tokenLogprobs = Self.tokenLogprobs(from: choice.logprobs?.content ?? [])
        return RouterCompletion(raw: raw, tokenLogprobs: tokenLogprobs)
    }

    public func chat(
        system: String,
        messages: [ChatMessage],
        params: SamplingParams,
        endpoint: LLMEndpoint,
        stream: Bool
    ) async throws -> ChatCompletionStream {
        var wireMessages = [ChatCompletionRequestBody.Message(role: ChatMessage.Role.system.rawValue, content: system)]
        wireMessages += messages.map { .init(role: $0.role.rawValue, content: $0.content) }

        let body = ChatCompletionRequestBody(
            model: endpoint.model,
            messages: wireMessages,
            temperature: params.temperature,
            topP: params.topP,
            maxTokens: params.maxTokens,
            stream: stream,
            logprobs: params.topLogprobs > 0,
            topLogprobs: params.topLogprobs > 0 ? params.topLogprobs : nil,
            grammar: nil)

        let request = try makeRequest(endpoint: endpoint, body: body)
        return stream ? try await streamedCompletion(request: request) : try await bufferedCompletion(request: request)
    }

    // MARK: - Non-streamed (buffered response, wrapped as a single-chunk stream)

    private func bufferedCompletion(request: URLRequest) async throws -> ChatCompletionStream {
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)

        let decoded = try JSONDecoder().decode(ChatCompletionResponseBody.self, from: data)
        guard let choice = decoded.choices.first else {
            throw InferenceClientError.emptyCompletion
        }
        let content = choice.message.content ?? ""
        let tokenLogprobs = Self.tokenLogprobs(from: choice.logprobs?.content ?? [])
        return ChatCompletionStream(chunks: [
            ChatCompletionChunk(delta: content, isFinal: true, logprobs: tokenLogprobs)
        ])
    }

    // MARK: - Streamed (SSE: `data: {...}\n\n`, terminated by `data: [DONE]`)

    private func streamedCompletion(request: URLRequest) async throws -> ChatCompletionStream {
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response)

        let stream = AsyncThrowingStream<ChatCompletionChunk, Error> { continuation in
            let task = Task {
                var byteOffset = 0
                do {
                    for try await line in bytes.lines {
                        guard let chunk = try Self.decodeSSELine(line, byteOffset: &byteOffset) else { continue }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return ChatCompletionStream(stream: stream)
    }

    /// Decode one SSE line into a chunk, or `nil` if the line carries nothing a caller
    /// needs to see (the blank event-separator lines `AsyncLineSequence` yields between
    /// events, the terminal `data: [DONE]` marker, and the very first "role announced,
    /// no content yet" chunk llama-server sends before any real token).
    private static func decodeSSELine(_ line: String, byteOffset: inout Int) throws -> ChatCompletionChunk? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let payloadData = payload.data(using: .utf8) else { return nil }

        let decoded = try JSONDecoder().decode(ChatCompletionChunkBody.self, from: payloadData)
        guard let choice = decoded.choices.first else { return nil }

        let logprobs = tokenLogprobs(from: choice.logprobs?.content ?? [], startingAt: &byteOffset)
        let delta = choice.delta.content ?? ""
        let isFinal = choice.finishReason != nil
        guard !delta.isEmpty || !logprobs.isEmpty || isFinal else { return nil }
        return ChatCompletionChunk(delta: delta, isFinal: isFinal, logprobs: logprobs)
    }

    // MARK: - Shared helpers

    private func makeRequest<Body: Encodable>(endpoint: LLMEndpoint, body: Body) throws -> URLRequest {
        let url = endpoint.baseURL.appending(path: "v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKeyRef = endpoint.apiKeyRef, !apiKeyRef.isEmpty {
            // Cloud target only — never populated for the local Sidecar. Real
            // Keychain-backed resolution of `apiKeyRef` is P6's job; this client only
            // needs the resulting bearer string, whatever produced it.
            request.setValue("Bearer \(apiKeyRef)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw InferenceClientError.unexpectedResponse(statusCode: (response as? HTTPURLResponse)?.statusCode)
        }
    }

    /// Convert wire logprob entries into `TokenLogprob`s with byte ranges aligned to the
    /// completion's UTF-8 bytes, starting fresh at offset 0 (the non-streamed path, where
    /// every token is known at once).
    private static func tokenLogprobs(from entries: [TokenLogprobEntry]) -> [TokenLogprob] {
        var offset = 0
        return tokenLogprobs(from: entries, startingAt: &offset)
    }

    /// Same conversion, but continuing from a running `offset` — the streamed path, where
    /// each SSE chunk's tokens must be positioned relative to everything already yielded.
    private static func tokenLogprobs(
        from entries: [TokenLogprobEntry], startingAt offset: inout Int
    ) -> [TokenLogprob] {
        entries.map { entry in
            let byteCount = entry.bytes?.count ?? entry.token.utf8.count
            let range = offset..<(offset + byteCount)
            offset += byteCount
            return TokenLogprob(token: entry.token, logprob: Float(entry.logprob), byteRange: range)
        }
    }
}
