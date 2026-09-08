import Foundation
import SkillManifest

/// A parsed Router Contract v2 object (docs/05-lld.md §2.2, §3.1): the model's
/// `{intent, skill_id, parameters}` decision, with **no** self-reported confidence.
/// Confidence is derived separately from token logprobs (LLD §4.2).
public struct RouterDecision: Equatable, Sendable {
    /// Short natural-language restatement of what the user wants.
    public let intent: String
    /// A registered skill id, or `nil` when the model emitted `skill_id: null`
    /// (nothing matched → prompt-back, never guess-execute).
    public let skillID: String?
    /// Parameters object, validated later against the chosen skill's schema.
    public let parameters: JSONValue

    public init(intent: String, skillID: String?, parameters: JSONValue) {
        self.intent = intent
        self.skillID = skillID
        self.parameters = parameters
    }
}
