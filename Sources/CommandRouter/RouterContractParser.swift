import Foundation
import LLMRuntime
import SkillManifest

/// Why a raw completion string could not be read as Router Contract v2
/// (docs/05-lld.md §2.2). Typed so callers never crash on a bad model emission.
public enum RouterContractError: Error, Equatable, Sendable {
    /// The string is not JSON, or is not a JSON object.
    case malformedJSON
    /// A required Contract v2 key is absent.
    case missingKey(String)
    /// A required key is present but the wrong JSON type.
    case wrongType(key: String)
    /// A key not in the Contract v2 schema (`additionalProperties: false`).
    case unexpectedKey(String)
    /// `intent` is present but empty (`minLength: 1`).
    case emptyIntent
    /// `intent` exceeds `maxLength: 200`.
    case intentTooLong
}

/// Parses GBNF-constrained Router Contract v2 JSON into a typed ``RouterDecision``.
/// Hard-rejects malformed JSON, missing keys, wrong types, extra keys, an empty
/// `intent`, and an `intent` longer than 200. Never crashes — every failure is a
/// ``RouterContractError``.
public enum RouterContractParser {

    private static let requiredKeys: Set<String> = ["intent", "skill_id", "parameters"]
    private static let maxIntentLength = 200

    /// Parse a JSON string as Contract v2.
    public static func parse(_ raw: String) throws -> RouterDecision {
        let object = try decodeObject(raw)
        try rejectExtraKeys(in: object)
        let intent = try requireIntent(in: object)
        let skillID = try requireSkillID(in: object)
        let parameters = try requireParameters(in: object)
        return RouterDecision(intent: intent, skillID: skillID, parameters: parameters)
    }

    /// Parse the raw text of a ``RouterCompletion``.
    public static func parse(_ completion: RouterCompletion) throws -> RouterDecision {
        try parse(completion.raw)
    }

    // MARK: - Decode

    private static func decodeObject(_ raw: String) throws -> [String: JSONValue] {
        guard let data = raw.data(using: .utf8) else {
            throw RouterContractError.malformedJSON
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw RouterContractError.malformedJSON
        }
        guard let object = value.objectValue else {
            throw RouterContractError.malformedJSON
        }
        return object
    }

    // MARK: - Keys

    private static func rejectExtraKeys(in object: [String: JSONValue]) throws {
        let extras = object.keys.filter { !requiredKeys.contains($0) }
        if let extra = extras.min() {
            throw RouterContractError.unexpectedKey(extra)
        }
    }

    private static func requireIntent(in object: [String: JSONValue]) throws -> String {
        guard let value = object["intent"] else {
            throw RouterContractError.missingKey("intent")
        }
        guard let intent = value.stringValue else {
            throw RouterContractError.wrongType(key: "intent")
        }
        if intent.isEmpty {
            throw RouterContractError.emptyIntent
        }
        if intent.count > maxIntentLength {
            throw RouterContractError.intentTooLong
        }
        return intent
    }

    private static func requireSkillID(in object: [String: JSONValue]) throws -> String? {
        guard let value = object["skill_id"] else {
            throw RouterContractError.missingKey("skill_id")
        }
        if value.isNull {
            return nil
        }
        guard let skillID = value.stringValue else {
            throw RouterContractError.wrongType(key: "skill_id")
        }
        return skillID
    }

    private static func requireParameters(in object: [String: JSONValue]) throws -> JSONValue {
        guard let value = object["parameters"] else {
            throw RouterContractError.missingKey("parameters")
        }
        guard value.objectValue != nil else {
            throw RouterContractError.wrongType(key: "parameters")
        }
        return value
    }
}
