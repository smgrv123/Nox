import CommandDispatcher
import SkillManifest

enum QuitApplicationSkill {
    static func run(
        parameters: JSONValue,
        system: any SystemSkillExecutor
    ) async throws -> SkillResult {
        let appName = try ParameterReader.requiredString("app_name", in: parameters)
        try await system.quitApplication(appName: appName)
        return SkillResult(summary: "Quit \(appName)")
    }
}
