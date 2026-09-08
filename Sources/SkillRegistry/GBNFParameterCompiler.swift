import SkillManifest

/// Compiles a JSON Schema subset (`Manifest.parameters`) into a GBNF object rule.
enum GBNFParameterCompiler {

    static func compileObject(_ schema: JSONValue) -> String {
        let fields = JSONSchemaObjectFields(schema)
        let requiredSet = Set(fields.requiredKeys)
        let optionalKeys = fields.properties.keys.filter { !requiredSet.contains($0) }.sorted()
        let body = joinProperties(
            requiredKeys: fields.requiredKeys,
            optionalKeys: optionalKeys,
            properties: fields.properties
        )
        if body.isEmpty {
            return #""{" ws "}""#
        }
        return "\"{\" ws \(body) ws \"}\""
    }

    private static func joinProperties(
        requiredKeys: [String],
        optionalKeys: [String],
        properties: [String: JSONValue]
    ) -> String {
        let requiredPieces = pieces(for: requiredKeys, in: properties)
        let optionalPieces = pieces(for: optionalKeys, in: properties)

        if requiredPieces.isEmpty {
            return wrapLeadingOptionals(optionalPieces)
        }

        var result = requiredPieces.joined(separator: " \",\" ws ")
        for piece in optionalPieces {
            result += " ( \",\" ws \(piece) )?"
        }
        return result
    }

    private static func pieces(for keys: [String], in properties: [String: JSONValue]) -> [String] {
        keys.compactMap { key in
            guard let schema = properties[key] else { return nil }
            return labeled(key, schema)
        }
    }

    private static func wrapLeadingOptionals(_ pieces: [String]) -> String {
        guard let first = pieces.first else { return "" }
        let rest = pieces.dropFirst().map { "( \",\" ws \($0) )?" }.joined(separator: " ")
        if rest.isEmpty {
            return "( \(first) )?"
        }
        return "( \(first) \(rest) )?"
    }

    private static func labeled(_ key: String, _ schema: JSONValue) -> String? {
        guard let type = compileType(schema) else { return nil }
        return "\"\\\"\(key)\\\":\" ws \(type)"
    }

    static func compileType(_ schema: JSONValue) -> String? {
        if let enumRule = compileEnum(schema) {
            return enumRule
        }
        switch schema["type"]?.stringValue {
        case "string":
            return "string"
        case "integer":
            return "integer"
        case "number":
            return "number"
        case "boolean":
            return "boolean"
        case "object":
            return compileObject(schema)
        case "array":
            return compileArray(schema)
        default:
            return nil
        }
    }

    private static func compileEnum(_ schema: JSONValue) -> String? {
        guard let values = schema["enum"]?.arrayValue, !values.isEmpty else {
            return nil
        }
        let alts = values.map(enumLiteral).joined(separator: " | ")
        return "(\(alts))"
    }

    private static func enumLiteral(_ value: JSONValue) -> String {
        if let string = value.stringValue {
            return "\"\\\"\(string)\\\"\""
        }
        if let int = value.intValue {
            return "\"\(int)\""
        }
        if let bool = value.boolValue {
            return "\"\(bool)\""
        }
        return "\"\\\"\\\"\""
    }

    private static func compileArray(_ schema: JSONValue) -> String? {
        guard let item = compileType(schema["items"] ?? .object(["type": .string("string")])) else {
            return nil
        }
        return "\"[\" ( \(item) ( \",\" ws \(item) )* )? \"]\""
    }
}
