import Foundation

/// Provisional routing-confidence thresholds (docs/05-lld.md §4.2). Every value is
/// **PROVISIONAL** — the day-one calibration harness (§7) replaces them with
/// data-fitted numbers after ~1 week — so they are **injected**, never hardcoded
/// final at a call site. Callers construct with `.provisional`; tests that need
/// the numeric policy compare against these properties, never inlined literals.
public struct RoutingThresholds: Equatable, Sendable {
    /// `L_mean ≥ routeHigh` → clearly high (confirm-tier executes silently).
    public let routeHigh: Float
    /// `routeLow ≤ L_mean < routeHigh` → marginal; `L_mean < routeLow` → weak.
    public let routeLow: Float

    public init(routeHigh: Float, routeLow: Float) {
        self.routeHigh = routeHigh
        self.routeLow = routeLow
    }

    /// The **PROVISIONAL** defaults, recalibrated from real-model measurement.
    /// The original docs/05-lld.md §4.2 example (`routeHigh: -0.15, routeLow: -0.7`)
    /// was fit to synthetic logprobs, not the real llama-server sidecar: a sample
    /// of real per-token routing-logprob means ranged **-0.72 to -5.08** across
    /// utterances — entirely below the old `routeLow: -0.7`, so every utterance
    /// would have been prompted back regardless of actual correctness. These
    /// literals instead bracket that measured range — `routeHigh` near its
    /// confident/upper end, `routeLow` near its weak/lower end — leaving a wide
    /// marginal band where `confirm`-tier skills still get a Confirm-Back rather
    /// than a silent guess. They remain **PROVISIONAL**: the day-one calibration
    /// harness (§7) replaces them with data-fitted numbers once real accepted/
    /// aborted/corrected outcomes accumulate in `logs/calibration.jsonl`. The
    /// literals live *here only*.
    public static let provisional = RoutingThresholds(routeHigh: -1.2, routeLow: -4.5)
}
