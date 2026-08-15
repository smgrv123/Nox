import Foundation

/// Decoding parameters for `LLMClient.chat` (docs/05-lld.md §3.3; plan Phase 3; User
/// Stories 1, 3, 5). `routeComplete` does **not** take a `SamplingParams` — its LLD
/// signature is fixed to `(system:user:grammar:endpoint:)` — so `InferenceClient` picks
/// its own conservative, low-temperature defaults for that grammar-constrained path
/// internally; this type is only ever a caller input for the free-form `chat` path.
public struct SamplingParams: Equatable, Sendable {
    public let temperature: Double
    public let topP: Double
    /// `nil` lets the Sidecar's own default (or the grammar/stop sequence) decide when to
    /// stop; a caller sets this to bound a runaway generation.
    public let maxTokens: Int?
    /// When `> 0`, requests per-token logprobs (`logprobs`/`top_logprobs` on the wire) —
    /// the future Router's confidence signal (LLD §4.2, P4) reads these off `chat` calls
    /// that opt in; `0` (the default) omits the logprobs request entirely.
    public let topLogprobs: Int

    public init(
        temperature: Double = 0.7,
        topP: Double = 1.0,
        maxTokens: Int? = nil,
        topLogprobs: Int = 0
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.topLogprobs = topLogprobs
    }

    public static let `default` = SamplingParams()
}
