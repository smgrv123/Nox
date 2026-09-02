import Foundation
import SkillManifest

extension ParameterValidator {

    static func validateValue(
        _ value: JSONValue,
        schema: JSONValue,
        path: String
    ) -> Result<Void, ParameterValidationError> {
        if let enumValues = schema["enum"]?.arrayValue {
            let enumResult = validateEnum(value, allowed: enumValues, path: path)
            if case .failure = enumResult {
                return enumResult
            }
        } else if let expected = schema["type"]?.stringValue {
            let typed = validateTypedValue(value, expected: expected, schema: schema, path: path)
            if case .failure = typed {
                return typed
            }
        }
        return validateKeywords(value, schema: schema, path: path)
    }

    private static func validateEnum(
        _ value: JSONValue,
        allowed: [JSONValue],
        path: String
    ) -> Result<Void, ParameterValidationError> {
        if allowed.contains(value) {
            return .success(())
        }
        return .failure(.invalidEnumValue(field: path, value: displayValue(value)))
    }

    private static func validateKeywords(
        _ value: JSONValue,
        schema: JSONValue,
        path: String
    ) -> Result<Void, ParameterValidationError> {
        if let string = value.stringValue {
            return validateStringKeywords(string, schema: schema, path: path)
        }
        return validateMinimum(value, schema: schema, path: path)
    }

    private static func validateMinimum(
        _ value: JSONValue,
        schema: JSONValue,
        path: String
    ) -> Result<Void, ParameterValidationError> {
        guard let number = jsonNumber(value) else {
            return .success(())
        }
        guard let minKeyword = schema["minimum"], let minimum = jsonNumber(minKeyword) else {
            return .success(())
        }
        if number < minimum {
            return .failure(
                .belowMinimum(field: path, value: displayValue(value), minimum: displayValue(minKeyword))
            )
        }
        return .success(())
    }

    private static func validateStringKeywords(
        _ string: String,
        schema: JSONValue,
        path: String
    ) -> Result<Void, ParameterValidationError> {
        if let minLength = schema["minLength"]?.intValue, string.count < minLength {
            return .failure(.belowMinLength(field: path, length: string.count, minLength: minLength))
        }
        if let maxLength = schema["maxLength"]?.intValue, string.count > maxLength {
            return .failure(.exceedsMaxLength(field: path, length: string.count, maxLength: maxLength))
        }
        if let pattern = schema["pattern"]?.stringValue {
            if !matchesPattern(pattern, string) {
                return .failure(.patternMismatch(field: path, value: string, pattern: pattern))
            }
        }
        return .success(())
    }

    private static func matchesPattern(_ pattern: String, _ string: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, range: range) != nil
    }

    private static func jsonNumber(_ value: JSONValue) -> Double? {
        if let int = value.intValue {
            return Double(int)
        }
        return value.doubleValue
    }

    private static func validateTypedValue(
        _ value: JSONValue,
        expected: String,
        schema: JSONValue,
        path: String
    ) -> Result<Void, ParameterValidationError> {
        switch expected {
        case "string":
            return expect(value, path: path, expected: "string") { $0.stringValue != nil }
        case "integer":
            return expect(value, path: path, expected: "integer") { $0.intValue != nil }
        case "number":
            return expectNumber(value, path: path)
        case "boolean":
            return expect(value, path: path, expected: "boolean") { $0.boolValue != nil }
        case "object":
            return validateNestedObject(value, schema: schema, path: path)
        case "array":
            return validateArray(value, schema: schema, path: path)
        default:
            return .success(())
        }
    }

    private static func expect(
        _ value: JSONValue,
        path: String,
        expected: String,
        matches: (JSONValue) -> Bool
    ) -> Result<Void, ParameterValidationError> {
        if matches(value) {
            return .success(())
        }
        return .failure(.typeMismatch(field: path, expected: expected, actual: jsonTypeName(value)))
    }

    private static func expectNumber(
        _ value: JSONValue,
        path: String
    ) -> Result<Void, ParameterValidationError> {
        if value.intValue != nil || value.doubleValue != nil {
            return .success(())
        }
        return .failure(.typeMismatch(field: path, expected: "number", actual: jsonTypeName(value)))
    }

    private static func validateNestedObject(
        _ value: JSONValue,
        schema: JSONValue,
        path: String
    ) -> Result<Void, ParameterValidationError> {
        guard let object = value.objectValue else {
            return .failure(.typeMismatch(field: path, expected: "object", actual: jsonTypeName(value)))
        }
        return validateObject(object, schema: schema, path: path)
    }

    private static func validateArray(
        _ value: JSONValue,
        schema: JSONValue,
        path: String
    ) -> Result<Void, ParameterValidationError> {
        guard let items = value.arrayValue else {
            return .failure(.typeMismatch(field: path, expected: "array", actual: jsonTypeName(value)))
        }
        guard let itemSchema = schema["items"] else {
            return .success(())
        }
        for (index, item) in items.enumerated() {
            let result = validateValue(item, schema: itemSchema, path: "\(path)[\(index)]")
            if case .failure = result {
                return result
            }
        }
        return .success(())
    }

    static func fieldPath(_ parent: String, _ key: String) -> String {
        parent.isEmpty ? key : "\(parent).\(key)"
    }

    static func jsonTypeName(_ value: JSONValue) -> String {
        switch value {
        case .string: return "string"
        case .int: return "integer"
        case .double: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func displayValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .null: return "null"
        case .array: return "array"
        case .object: return "object"
        }
    }
}
