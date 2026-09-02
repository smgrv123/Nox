import AideCore
import DangerousCommandScanner

/// Payload for a Confirm-Back Overlay: the resolved action, optional scanner
/// findings, and the skill's declared Risk Tier.
public struct ConfirmBackPrompt: Equatable, Sendable {
    public let intent: String
    public let skillID: String
    public let findings: [Finding]?
    public let riskTier: RiskTier

    public init(
        intent: String,
        skillID: String,
        findings: [Finding]?,
        riskTier: RiskTier
    ) {
        self.intent = intent
        self.skillID = skillID
        self.findings = findings
        self.riskTier = riskTier
    }
}
