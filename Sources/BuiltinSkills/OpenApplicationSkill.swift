import CommandDispatcher
import SkillManifest

enum OpenApplicationSkill {
    static func run(
        parameters: JSONValue,
        system: any SystemSkillExecutor
    ) async throws -> SkillResult {
        let appName = try ParameterReader.requiredString("app_name", in: parameters)
        try await system.openApplication(appName: appName)
        return SkillResult(summary: "Opened \(appName)")
    }
}
