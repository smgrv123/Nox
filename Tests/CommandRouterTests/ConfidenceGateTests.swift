import AideCore
import SkillManifest
import XCTest

@testable import CommandRouter

/// Pins LLD §3.1 / §4.2 Confidence Gate behaviour: null skill, schema hard-reject,
/// and Risk Tier × `L_mean` (against **injected** thresholds) decide execute /
/// Confirm-Back / prompt-back. Pre-Gate is already applied upstream; Hard-Block
/// is Phase 5. Threshold literals never appear in assertions — inputs are built
/// relative to the injected struct (same style as `SegmentPreGateTests`).
final class ConfidenceGateTests: XCTestCase {

    /// Test-local thresholds. Deliberately not `.provisional` so the suite owns
    /// its numbers and every logprob below is constructed relative to *these*.
    private let thresholds = RoutingThresholds(routeHigh: -0.15, routeLow: -0.7)

    private var gate: ConfidenceGate { ConfidenceGate(thresholds: thresholds) }

    func testNullSkillPromptsBackRegardlessOfConfidence() {
        let intent = routed(skillID: nil, logprobMean: thresholds.routeHigh + 0.05)
        let decision = gate.decide(intent, riskTier: .low, schemaValid: true)

        XCTAssertEqual(decision, .promptBack(suggestion: ConfidenceGate.promptBackSuggestion))
    }

    func testSchemaValidationFailPromptsBack() {
        let intent = routed(logprobMean: thresholds.routeHigh + 0.05)
        let decision = gate.decide(intent, riskTier: .low, schemaValid: false)

        XCTAssertEqual(decision, .promptBack(suggestion: ConfidenceGate.promptBackSuggestion))
    }

    func testLowTierAboveFloorExecutes() {
        let intent = routed(logprobMean: thresholds.routeLow + 0.05)
        let decision = gate.decide(intent, riskTier: .low, schemaValid: true)

        XCTAssertEqual(decision, .execute)
    }

    func testLowTierBelowRouteLowPromptsBack() {
        let intent = routed(logprobMean: thresholds.routeLow - 0.05)
        let decision = gate.decide(intent, riskTier: .low, schemaValid: true)

        XCTAssertEqual(decision, .promptBack(suggestion: ConfidenceGate.promptBackSuggestion))
    }

    func testConfirmTierHighLogprobExecutes() {
        let intent = routed(logprobMean: thresholds.routeHigh)
        let decision = gate.decide(intent, riskTier: .confirm, schemaValid: true)

        XCTAssertEqual(decision, .execute)
    }

    func testConfirmTierMarginalLogprobConfirmsBack() {
        let midpoint = (thresholds.routeLow + thresholds.routeHigh) / 2
        let intent = routed(logprobMean: midpoint)
        let decision = gate.decide(intent, riskTier: .confirm, schemaValid: true)

        XCTAssertEqual(decision, .confirmBack(prompt: ConfidenceGate.confirmBackPrompt))
    }

    func testConfirmTierBelowRouteLowPromptsBack() {
        let intent = routed(logprobMean: thresholds.routeLow - 0.05)
        let decision = gate.decide(intent, riskTier: .confirm, schemaValid: true)

        XCTAssertEqual(decision, .promptBack(suggestion: ConfidenceGate.promptBackSuggestion))
    }

    func testAlwaysConfirmHighLogprobConfirmsBack() {
        let intent = routed(logprobMean: thresholds.routeHigh + 0.05)
        let decision = gate.decide(intent, riskTier: .alwaysConfirm, schemaValid: true)

        XCTAssertEqual(decision, .confirmBack(prompt: ConfidenceGate.confirmBackPrompt))
    }

    func testAlwaysConfirmLowLogprobConfirmsBack() {
        let intent = routed(logprobMean: thresholds.routeLow - 0.05)
        let decision = gate.decide(intent, riskTier: .alwaysConfirm, schemaValid: true)

        XCTAssertEqual(decision, .confirmBack(prompt: ConfidenceGate.confirmBackPrompt))
    }

    func testInjectedThresholdsChangeGateOutcome() {
        let logprob: Float = -0.20
        let loose = RoutingThresholds(routeHigh: logprob - 0.10, routeLow: logprob - 0.50)
        let tight = RoutingThresholds(routeHigh: logprob + 0.10, routeLow: logprob - 0.50)
        let intent = routed(logprobMean: logprob)

        let withLoose = ConfidenceGate(thresholds: loose).decide(
            intent, riskTier: .confirm, schemaValid: true)
        let withTight = ConfidenceGate(thresholds: tight).decide(
            intent, riskTier: .confirm, schemaValid: true)

        XCTAssertEqual(withLoose, .execute)
        XCTAssertEqual(withTight, .confirmBack(prompt: ConfidenceGate.confirmBackPrompt))
    }
}

// MARK: - Fixtures

extension ConfidenceGateTests {

    fileprivate func routed(
        skillID: String? = "open_application",
        intent: String = "open Safari",
        logprobMean: Float
    ) -> RoutedIntent {
        RoutedIntent(
            decision: RouterDecision(
                intent: intent, skillID: skillID, parameters: .object([:])),
            confidence: RoutingConfidence(
                idSelectingTokenCount: 1, logprobSum: logprobMean, logprobMean: logprobMean))
    }
}
