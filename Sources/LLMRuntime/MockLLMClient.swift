import Foundation

/// The deterministic, native-process-free conformer of `LLMClient` (docs/05-lld.md §3.3;
/// plan Phase 3; User Story 19) — mirrors `SpeechToText.MockSTTEngine`'s role for P2a.
/// Returns caller-injected results verbatim (or throws a caller-injected error), so
/// P4/P5/P6 can develop and test against `LLMClient` without a live Sidecar. The real
/// `InferenceClient` swaps in behind the same protocol with no change to callers.
public actor MockLLMClient: LLMClient {

    /// How many times `routeComplete`/`chat` has been called — lets tests assert calls
    /// happened without a live Sidecar to observe.
    public private(set) var routeCompleteCallCount = 0
    public private(set) var chatCallCount = 0

    private var routeCompletionResult: Result<RouterCompletion, Error>
    private var chatChunksResult: Result<[ChatCompletionChunk], Error>

    /// - Parameters:
    ///   - routeCompletion: the canned result every `routeComplete` call returns, until
    ///     `setRouteCompletion` reconfigures it.
    ///   - chatChunks: the canned chunk sequence every `chat` call's returned
    ///     `ChatCompletionStream` yields, until `setChatChunks` reconfigures it. `chat`'s
    ///     own `stream` argument does not change this mock's behavior — a real Sidecar's
    ///     wire mode is `InferenceClient`'s concern, not the seam's.
    public init(
        routeCompletion: RouterCompletion = RouterCompletion(raw: "", tokenLogprobs: []),
        chatChunks: [ChatCompletionChunk] = []
    ) {
        self.routeCompletionResult = .success(routeCompletion)
        self.chatChunksResult = .success(chatChunks)
    }

    /// Reconfigure what the next `routeComplete` call(s) return — a canned completion, or
    /// a thrown error (e.g. to exercise a caller's failure-handling path).
    public func setRouteCompletion(_ result: Result<RouterCompletion, Error>) {
        routeCompletionResult = result
    }

    /// Reconfigure what the next `chat` call(s)' stream yields.
    public func setChatChunks(_ result: Result<[ChatCompletionChunk], Error>) {
        chatChunksResult = result
    }

    // MARK: - LLMClient

    public func routeComplete(
        system: String,
        user: String,
        grammar: String,
        endpoint: LLMEndpoint
    ) async throws -> RouterCompletion {
        routeCompleteCallCount += 1
        return try routeCompletionResult.get()
    }

    public func chat(
        system: String,
        messages: [ChatMessage],
        params: SamplingParams,
        endpoint: LLMEndpoint,
        stream: Bool
    ) async throws -> ChatCompletionStream {
        chatCallCount += 1
        let chunks = try chatChunksResult.get()
        return ChatCompletionStream(chunks: chunks)
    }
}
