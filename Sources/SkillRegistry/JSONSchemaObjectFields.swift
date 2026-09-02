import SkillManifest

/// The `properties` map and `required` key list from a JSON Schema object.
struct JSONSchemaObjectFields {
    let properties: [String: JSONValue]
    let requiredKeys: [String]

    init(_ schema: JSONValue) {
        properties = schema["properties"]?.objectValue ?? [:]
        requiredKeys = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}
