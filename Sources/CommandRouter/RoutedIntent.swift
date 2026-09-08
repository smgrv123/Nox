import Foundation

/// The Router's public result: a parsed Contract v2 decision plus the
/// logprob-derived confidence measured at the `skill_id`-selecting tokens.
public struct RoutedIntent: Equatable, Sendable {
    public let decision: RouterDecision
    public let confidence: RoutingConfidence

    public init(decision: RouterDecision, confidence: RoutingConfidence) {
        self.decision = decision
        self.confidence = confidence
    }
}
