/// Hard-rejection failures when router-emitted parameters do not match a skill schema.
public enum ParameterValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownSkillID(String)
    case parametersNotObject
    case missingRequiredField(String)
    case typeMismatch(field: String, expected: String, actual: String)
    case additionalProperty(String)
    case invalidEnumValue(field: String, value: String)
    case belowMinimum(field: String, value: String, minimum: String)
    case exceedsMaxLength(field: String, length: Int, maxLength: Int)
    case belowMinLength(field: String, length: Int, minLength: Int)
    case patternMismatch(field: String, value: String, pattern: String)

    public var description: String {
        switch self {
        case .unknownSkillID(let id):
            return "unknown skill id: \(id)"
        case .parametersNotObject:
            return "parameters must be a JSON object"
        case .missingRequiredField(let field):
            return "missing required field: \(field)"
        case .typeMismatch(let field, let expected, let actual):
            return "field \(field): expected \(expected), got \(actual)"
        case .additionalProperty(let name):
            return "additional property not allowed: \(name)"
        case .invalidEnumValue(let field, let value):
            return "field \(field): value \(value) is not an allowed enum member"
        case .belowMinimum(let field, let value, let minimum):
            return "field \(field): value \(value) is below minimum \(minimum)"
        case .exceedsMaxLength(let field, let length, let maxLength):
            return "field \(field): length \(length) exceeds maxLength \(maxLength)"
        case .belowMinLength(let field, let length, let minLength):
            return "field \(field): length \(length) is below minLength \(minLength)"
        case .patternMismatch(let field, let value, let pattern):
            return "field \(field): value \(value) does not match pattern \(pattern)"
        }
    }
}
