import SkillManifest

/// Generates the `{{SKILL_CATALOG}}` fragment injected into the router system prompt
/// (LLD §6.1): id, description, a parameter-schema summary, and utterance examples.
public enum RouterPromptCatalog {

    public static func render(from manifests: [Manifest]) -> String {
        manifests
            .sorted { $0.id < $1.id }
            .map(renderSkill)
            .joined(separator: "\n\n")
    }

    private static func renderSkill(_ manifest: Manifest) -> String {
        var lines = [
            manifest.id,
            "  description: \(manifest.description)",
            "  parameters: \(summarizeParameters(manifest.parameters))",
        ]
        if !manifest.utteranceExamples.isEmpty {
            let examples = manifest.utteranceExamples.map { "\"\($0)\"" }.joined(separator: "; ")
            lines.append("  examples: \(examples)")
        }
        return lines.joined(separator: "\n")
    }

    private static func summarizeParameters(_ schema: JSONValue) -> String {
        let fields = JSONSchemaObjectFields(schema)
        guard !fields.properties.isEmpty else {
            return "(none)"
        }
        let required = Set(fields.requiredKeys)
        let optionalKeys = fields.properties.keys.filter { !required.contains($0) }.sorted()
        let ordered = fields.requiredKeys.filter { fields.properties[$0] != nil } + optionalKeys
        let parts = ordered.compactMap { key -> String? in
            guard let prop = fields.properties[key] else { return nil }
            let typeName = typeSummary(prop)
            if required.contains(key) {
                return "\(key): \(typeName) (required)"
            }
            return "\(key): \(typeName)"
        }
        return parts.joined(separator: "; ")
    }

    private static func typeSummary(_ schema: JSONValue) -> String {
        if schema["enum"] != nil {
            return "enum"
        }
        switch schema["type"]?.stringValue {
        case "integer":
            return "integer"
        case "number":
            return "number"
        case "boolean":
            return "boolean"
        case "object":
            return "object"
        case "array":
            return "array"
        default:
            return "string"
        }
    }
}
