import Foundation

/// ONE OpenAI-compatible client for both the local Sidecar and any BYOK cloud endpoint
/// (docs/05-lld.md §3.3 — normative; locked stack; plan Phase 3; User Stories 1-5, 19).
/// Only `endpoint` (and its auth) differs between the two targets — that is what makes
/// the future Local/Cloud Indicator (P6) a single auditable choke point.
///
/// `InferenceClient` (the `InferenceClient` module) is the real, `URLSession`-based
/// conformer; `MockLLMClient` (this module) is the deterministic, native-process-free
/// conformer P4/P5/P6 develop against before the real Sidecar exists.
public protocol LLMClient: Sendable {
    /// Grammar-constrained completion (the future Router, P4). Passthrough only in P2b:
    /// `grammar` is forwarded to the Sidecar unmodified — this client does not generate
    /// or interpret it. Always requests logprobs so P4's confidence measurement (LLD
    /// §4.2) has something to read.
    func routeComplete(
        system: String,
        user: String,
        grammar: String,
        endpoint: LLMEndpoint
    ) async throws -> RouterCompletion

    /// Free-form chat completion (general Q&A, dictation cleanup, script generation —
    /// P5/P6). Supports both streamed and non-streamed responses through the same
    /// `ChatCompletionStream` return type (see its doc comment).
    func chat(
        system: String,
        messages: [ChatMessage],
        params: SamplingParams,
        endpoint: LLMEndpoint,
        stream: Bool
    ) async throws -> ChatCompletionStream
}
