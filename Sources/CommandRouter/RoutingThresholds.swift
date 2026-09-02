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

    /// The **PROVISIONAL** defaults from docs/05-lld.md §4.2. The literals live
    /// *here only*.
    public static let provisional = RoutingThresholds(routeHigh: -0.15, routeLow: -0.7)
}
