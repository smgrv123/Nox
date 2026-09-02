import SkillManifest

enum ParameterReader {
    static func object(_ parameters: JSONValue) throws -> [String: JSONValue] {
        guard let object = parameters.objectValue else {
            throw SkillExecutionError.invalidParameters
        }
        return object
    }

    static func requiredString(_ key: String, in parameters: JSONValue) throws -> String {
        let fields = try object(parameters)
        guard let value = fields[key]?.stringValue, !value.isEmpty else {
            throw SkillExecutionError.missingParameter(key)
        }
        return value
    }

    static func optionalString(_ key: String, in parameters: JSONValue) -> String? {
        guard let raw = parameters[key], !raw.isNull else { return nil }
        let value = raw.stringValue
        if value?.isEmpty == true { return nil }
        return value
    }

    static func requiredInt(_ key: String, in parameters: JSONValue) throws -> Int {
        let fields = try object(parameters)
        if let int = fields[key]?.intValue {
            return int
        }
        throw SkillExecutionError.missingParameter(key)
    }

    static func requiredDouble(_ key: String, in parameters: JSONValue) throws -> Double {
        let fields = try object(parameters)
        if let double = fields[key]?.doubleValue {
            return double
        }
        if let int = fields[key]?.intValue {
            return Double(int)
        }
        throw SkillExecutionError.missingParameter(key)
    }
}
