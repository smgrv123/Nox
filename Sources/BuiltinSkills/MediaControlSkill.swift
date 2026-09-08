import CommandDispatcher
import SkillManifest

enum MediaControlSkill {
    private static let allowed = Set(["play", "pause", "next", "previous", "toggle"])

    static func run(
        parameters: JSONValue,
        system: any SystemSkillExecutor
    ) async throws -> SkillResult {
        let action = try ParameterReader.requiredString("action", in: parameters)
        guard allowed.contains(action) else {
            throw SkillExecutionError.unsupportedMediaAction(action)
        }
        try await system.mediaControl(action: action)
        return SkillResult(summary: "Media \(action)")
    }
}
