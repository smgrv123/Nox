import SkillManifest

/// Validates router-emitted `parameters` against a manifest JSON Schema subset.
///
/// Shape is guaranteed by GBNF; this check is the post-generation hard rejection
/// for required fields, types, enums, and additional properties (LLD §4.4 / §5.3).
public enum ParameterValidator {

    public static func validate(
        parameters: JSONValue,
        against schema: JSONValue
    ) -> Result<Void, ParameterValidationError> {
        guard let object = parameters.objectValue else {
            return .failure(.parametersNotObject)
        }
        return validateObject(object, schema: schema, path: "")
    }

    static func validateObject(
        _ object: [String: JSONValue],
        schema: JSONValue,
        path: String
    ) -> Result<Void, ParameterValidationError> {
        let fields = JSONSchemaObjectFields(schema)

        if let missing = firstMissingRequired(fields.requiredKeys, in: object, path: path) {
            return .failure(.missingRequiredField(missing))
        }

        if additionalPropertiesForbidden(schema) {
            if let extra = object.keys.sorted().first(where: { fields.properties[$0] == nil }) {
                return .failure(.additionalProperty(fieldPath(path, extra)))
            }
        }

        for (key, value) in object {
            guard let propSchema = fields.properties[key] else { continue }
            let result = validateValue(value, schema: propSchema, path: fieldPath(path, key))
            if case .failure = result {
                return result
            }
        }
        return .success(())
    }

    private static func firstMissingRequired(
        _ required: [String],
        in object: [String: JSONValue],
        path: String
    ) -> String? {
        required.first { object[$0] == nil }.map { fieldPath(path, $0) }
    }

    private static func additionalPropertiesForbidden(_ schema: JSONValue) -> Bool {
        guard let flag = schema["additionalProperties"] else {
            return true
        }
        return flag.boolValue != true
    }
}
