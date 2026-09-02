import AideCore
import Foundation

/// Deterministic Confidence Gate (docs/05-lld.md §3.1 / §4.2): combines
/// routing confidence, schema-validation result, and Risk Tier into a
/// ``GateDecision``. Pre-Gate is already applied upstream — this type does
/// not re-run `SegmentPreGate` or JSON Schema.
public struct ConfidenceGate: Sendable {

    /// Honest "Did you mean…?" copy for every prompt-back. Single source;
    /// tests assert this constant, never a re-typed literal.
    public static let promptBackSuggestion = "Did you mean…?"

    /// Confirm-Back copy when an action was resolved but must not auto-run.
    public static let confirmBackPrompt = "Approve this action before Aide runs it."

    /// Injected provisional thresholds — never hardcoded inside `decide`.
    public let thresholds: RoutingThresholds

    public init(thresholds: RoutingThresholds) {
        self.thresholds = thresholds
    }

    /// Apply the LLD §3.1 / Phase 4 AC order. `schemaValid` is the already-
    /// computed SkillRegistry validation result (pass/fail) — this gate does
    /// not re-run JSON Schema.
    public func decide(
        _ intent: RoutedIntent,
        riskTier: RiskTier,
        schemaValid: Bool
    ) -> GateDecision {
        if intent.decision.skillID == nil {
            return Self.promptBack
        }
        if !schemaValid {
            return Self.promptBack
        }
        if riskTier == .alwaysConfirm {
            return .confirmBack(prompt: Self.confirmBackPrompt)
        }
        let mean = intent.confidence.logprobMean
        if mean < thresholds.routeLow {
            return Self.promptBack
        }
        if riskTier == .confirm, mean < thresholds.routeHigh {
            return .confirmBack(prompt: Self.confirmBackPrompt)
        }
        return .execute
    }

    /// Shared prompt-back for unresolved skill, schema hard-reject, and
    /// `L_mean` below `routeLow`.
    private static var promptBack: GateDecision {
        .promptBack(suggestion: promptBackSuggestion)
    }
}
