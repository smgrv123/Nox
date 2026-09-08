import Foundation

/// Describes a specific validation failure in a manifest.
public enum ValidationIssue: Sendable, Hashable, CustomStringConvertible {
    case invalidID
    case descriptionOutOfRange
    case tooManyUtteranceExamples
    case parametersMustBeObject
    case userAutomationMissingScriptRef
    case userAutomationMissingScriptSha256
    case builtinMustNotHaveScriptRef
    case timeoutOutOfRange
    case unsupportedSchemaVersion

    public var description: String {
        switch self {
        case .invalidID:
            return "id must match ^[a-z][a-z0-9_]{2,63}$"
        case .descriptionOutOfRange:
            return "description must be 3-400 characters"
        case .tooManyUtteranceExamples:
            return "utterance_examples must have at most 8 entries"
        case .parametersMustBeObject:
            return "parameters must be a JSON object with \"type\": \"object\""
        case .userAutomationMissingScriptRef:
            return "user_automation manifest requires a non-nil script_ref"
        case .userAutomationMissingScriptSha256:
            return "user_automation manifest requires a non-nil script_sha256"
        case .builtinMustNotHaveScriptRef:
            return "builtin manifest must not have a script_ref"
        case .timeoutOutOfRange:
            return "timeout_seconds must be in range 1-3600"
        case .unsupportedSchemaVersion:
            return "schema_version must be 1"
        }
    }
}

/// Validates a ``Manifest`` against the schema rules from LLD §2.1.
///
/// Returns an empty array when the manifest is valid. A non-empty array
/// means the skill should be disabled (but never crash).
public enum ManifestValidation {

    private static let idPattern: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(pattern: "^[a-z][a-z0-9_]{2,63}$") else {
            preconditionFailure("Built-in regex pattern must compile")
        }
        return regex
    }()

    public static func validate(_ manifest: Manifest) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if !isValidID(manifest.id) {
            issues.append(.invalidID)
        }

        if manifest.schemaVersion != 1 {
            issues.append(.unsupportedSchemaVersion)
        }

        if manifest.description.count < 3 || manifest.description.count > 400 {
            issues.append(.descriptionOutOfRange)
        }

        if manifest.utteranceExamples.count > 8 {
            issues.append(.tooManyUtteranceExamples)
        }

        if !isParametersObject(manifest.parameters) {
            issues.append(.parametersMustBeObject)
        }

        if manifest.kind == .userAutomation {
            if manifest.scriptRef == nil {
                issues.append(.userAutomationMissingScriptRef)
            }
            if manifest.scriptSha256 == nil {
                issues.append(.userAutomationMissingScriptSha256)
            }
        }

        if manifest.kind == .builtin && manifest.scriptRef != nil {
            issues.append(.builtinMustNotHaveScriptRef)
        }

        if manifest.timeoutSeconds < 1 || manifest.timeoutSeconds > 3600 {
            issues.append(.timeoutOutOfRange)
        }

        return issues
    }

    private static func isValidID(_ id: String) -> Bool {
        let range = NSRange(id.startIndex..., in: id)
        return idPattern.firstMatch(in: id, range: range) != nil
    }

    private static func isParametersObject(_ params: JSONValue) -> Bool {
        guard let obj = params.objectValue else { return false }
        return obj["type"]?.stringValue == "object"
    }
}
