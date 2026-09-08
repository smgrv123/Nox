import Foundation

/// Logprob-derived routing confidence (docs/05-lld.md §4.2). Measured at the
/// `skill_id`-selecting tokens only — never a model-emitted field.
public struct RoutingConfidence: Equatable, Sendable {
    /// How many `TokenLogprob`s overlapped the `skill_id` value literal.
    public let idSelectingTokenCount: Int
    /// `L_sum = Σ t.logprob` over the id-selecting tokens.
    public let logprobSum: Float
    /// `L_mean = L_sum / |T|` — the primary confidence signal.
    public let logprobMean: Float

    public init(idSelectingTokenCount: Int, logprobSum: Float, logprobMean: Float) {
        self.idSelectingTokenCount = idSelectingTokenCount
        self.logprobSum = logprobSum
        self.logprobMean = logprobMean
    }
}
