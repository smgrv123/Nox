import Foundation

/// Failures the router surfaces as thrown errors (dispatcher `.failed`).
/// Malformed calculate expressions are *not* this type — they become a
/// human-readable ``SkillResult`` so they never crash the overlay path.
enum SkillExecutionError: Error, Equatable, LocalizedError {
    case unknownSkill(String)
    case missingParameter(String)
    case invalidParameters
    case unknownTimezone(String)
    case unsupportedMediaAction(String)

    var errorDescription: String? {
        switch self {
        case .unknownSkill(let id):
            return "unknown skill: \(id)"
        case .missingParameter(let key):
            return "missing parameter: \(key)"
        case .invalidParameters:
            return "parameters must be an object"
        case .unknownTimezone(let name):
            return "unknown timezone: \(name)"
        case .unsupportedMediaAction(let action):
            return "unsupported media action: \(action)"
        }
    }
}
