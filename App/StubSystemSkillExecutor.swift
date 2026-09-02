import BuiltinSkills
import Foundation

/// Phase 2 placeholder: effectful skills are not wired to AppKit yet.
/// Pure skills (`current_time`, `calculate`) never call this type.
struct StubSystemSkillExecutor: SystemSkillExecutor {

    func openApplication(appName _: String) async throws {
        throw StubSystemSkillError.notWired("open_application")
    }

    func quitApplication(appName _: String) async throws {
        throw StubSystemSkillError.notWired("quit_application")
    }

    func setTimer(durationSeconds _: Int, label _: String?) async throws {
        throw StubSystemSkillError.notWired("set_timer")
    }

    func mediaControl(action _: String) async throws {
        throw StubSystemSkillError.notWired("media_control")
    }

    func takeScreenshot(region _: String?) async throws -> String {
        throw StubSystemSkillError.notWired("take_screenshot")
    }
}

enum StubSystemSkillError: LocalizedError {
    case notWired(String)

    var errorDescription: String? {
        switch self {
        case .notWired(let skillID):
            return "\(skillID): not yet wired"
        }
    }
}
