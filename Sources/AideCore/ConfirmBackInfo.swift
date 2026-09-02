import Foundation

/// Lightweight Confirm-Back payload for the Overlay (AideCore cannot depend on
/// `CommandDispatcher.ConfirmBackPrompt`).
public struct ConfirmBackInfo: Equatable, Sendable {
    public let transcript: String
    public let intent: String
    public let skillID: String
    public let riskTier: RiskTier

    public init(transcript: String, intent: String, skillID: String, riskTier: RiskTier) {
        self.transcript = transcript
        self.intent = intent
        self.skillID = skillID
        self.riskTier = riskTier
    }
}
