import CommandDispatcher
import SkillManifest

enum TakeScreenshotSkill {
    static func run(
        parameters: JSONValue,
        system: any SystemSkillExecutor
    ) async throws -> SkillResult {
        let region = canonicalRegion(ParameterReader.optionalString("region", in: parameters))
        let path = try await system.takeScreenshot(region: region)
        return SkillResult(summary: "Saved screenshot to \(path)")
    }

    /// Plan vocabulary is `full` / `window` / `selection`. `full_screen` is a
    /// legacy alias of `full`.
    private static func canonicalRegion(_ raw: String?) -> String? {
        switch raw {
        case "full_screen": return "full"
        default: return raw
        }
    }
}
