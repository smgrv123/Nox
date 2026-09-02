import Foundation

/// A recursive, type-safe representation of arbitrary JSON values.
///
/// Used for the manifest `parameters` field (a JSON Schema subset) and
/// for parameter values passed at runtime. Supports all JSON types:
/// string, integer, floating-point, boolean, null, array, and object.
public enum JSONValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    indirect case object([String: JSONValue])
}

// MARK: - Convenience accessors

extension JSONValue {

    public var stringValue: String? {
        guard case .string(let val) = self else { return nil }
        return val
    }

    public var intValue: Int? {
        guard case .int(let val) = self else { return nil }
        return val
    }

    public var doubleValue: Double? {
        guard case .double(let val) = self else { return nil }
        return val
    }

    public var boolValue: Bool? {
        guard case .bool(let val) = self else { return nil }
        return val
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let val) = self else { return nil }
        return val
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let val) = self else { return nil }
        return val
    }

    public var isNull: Bool {
        guard case .null = self else { return false }
        return true
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

// MARK: - Codable

extension JSONValue: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
            return
        }

        if let intVal = try? container.decode(Int.self) {
            let doubleVal = try container.decode(Double.self)
            if doubleVal == Double(intVal) {
                self = .int(intVal)
            } else {
                self = .double(doubleVal)
            }
            return
        }

        if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
            return
        }

        if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
            return
        }

        if let arrayVal = try? container.decode([JSONValue].self) {
            self = .array(arrayVal)
            return
        }

        if let objectVal = try? container.decode([String: JSONValue].self) {
            self = .object(objectVal)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "JSONValue could not decode any known JSON type"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let val):
            try container.encode(val)
        case .int(let val):
            try container.encode(val)
        case .double(let val):
            try container.encode(val)
        case .bool(let val):
            try container.encode(val)
        case .null:
            try container.encodeNil()
        case .array(let val):
            try container.encode(val)
        case .object(let val):
            try container.encode(val)
        }
    }
}
