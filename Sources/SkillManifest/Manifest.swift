import AideCore
import Foundation

/// The complete on-disk representation of a Skill or Automation manifest.
///
/// Maps to the JSON schema defined in LLD §2.1. Covers both built-in
/// (Swift-backed) skills and user script automations. An invalid manifest
/// disables that skill only — it never crashes the app.
public struct Manifest: Sendable, Hashable {
    public var schemaVersion: Int
    public var id: String
    public var kind: ManifestKind
    public var displayName: String?
    public var description: String
    public var utteranceExamples: [String]
    public var parameters: JSONValue
    public var permissions: ManifestPermissions
    public var schedule: ManifestSchedule?
    public var riskTier: RiskTier
    public var enabled: Bool
    public var scriptRef: String?
    public var scriptSha256: String?
    public var timeoutSeconds: Int
    public var failureState: FailureState
    public var createdAt: Date?
    public var updatedAt: Date?
    public var generatedBy: GeneratedBy

    public init(
        schemaVersion: Int = 1,
        id: String,
        kind: ManifestKind,
        displayName: String? = nil,
        description: String,
        utteranceExamples: [String] = [],
        parameters: JSONValue,
        permissions: ManifestPermissions,
        schedule: ManifestSchedule? = nil,
        riskTier: RiskTier,
        enabled: Bool = true,
        scriptRef: String? = nil,
        scriptSha256: String? = nil,
        timeoutSeconds: Int = 60,
        failureState: FailureState = FailureState(),
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        generatedBy: GeneratedBy = .builtin
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.description = description
        self.utteranceExamples = utteranceExamples
        self.parameters = parameters
        self.permissions = permissions
        self.schedule = schedule
        self.riskTier = riskTier
        self.enabled = enabled
        self.scriptRef = scriptRef
        self.scriptSha256 = scriptSha256
        self.timeoutSeconds = timeoutSeconds
        self.failureState = failureState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.generatedBy = generatedBy
    }
}

// MARK: - Codable

extension Manifest: Codable {

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case kind
        case displayName
        case description
        case utteranceExamples
        case parameters
        case permissions
        case schedule
        case riskTier
        case enabled
        case scriptRef
        case scriptSha256
        case timeoutSeconds
        case failureState
        case createdAt
        case updatedAt
        case generatedBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.id = try container.decode(String.self, forKey: .id)
        self.kind = try container.decode(ManifestKind.self, forKey: .kind)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.description = try container.decode(String.self, forKey: .description)
        self.utteranceExamples = try container.decodeIfPresent([String].self, forKey: .utteranceExamples) ?? []
        self.parameters = try container.decode(JSONValue.self, forKey: .parameters)
        self.permissions = try container.decode(ManifestPermissions.self, forKey: .permissions)
        self.schedule = try container.decodeIfPresent(ManifestSchedule.self, forKey: .schedule)
        self.riskTier = try container.decode(RiskTier.self, forKey: .riskTier)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.scriptRef = try container.decodeIfPresent(String.self, forKey: .scriptRef)
        self.scriptSha256 = try container.decodeIfPresent(String.self, forKey: .scriptSha256)
        self.timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
        self.failureState = try container.decodeIfPresent(FailureState.self, forKey: .failureState) ?? FailureState()
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.generatedBy = try container.decodeIfPresent(GeneratedBy.self, forKey: .generatedBy) ?? .builtin
    }
}
