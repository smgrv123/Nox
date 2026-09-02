import CommandDispatcher
import SkillManifest

enum SetTimerSkill {
    static func run(
        parameters: JSONValue,
        system: any SystemSkillExecutor
    ) async throws -> SkillResult {
        let seconds = try ParameterReader.requiredInt("duration_seconds", in: parameters)
        let label = ParameterReader.optionalString("label", in: parameters)
        try await system.setTimer(durationSeconds: seconds, label: label)
        if let label {
            return SkillResult(summary: "Timer '\(label)' set for \(seconds) seconds")
        }
        return SkillResult(summary: "Timer set for \(seconds) seconds")
    }
}
