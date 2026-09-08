import Foundation

/// Whether the skill is a Swift-backed builtin or a user-authored script automation.
public enum ManifestKind: String, Codable, Sendable, Hashable {
    case builtin
    case userAutomation = "user_automation"
}
