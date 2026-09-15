import CommandDispatcher
import Foundation
import Personalization
import SkillManifest

/// Routes a built-in `skillID` to its Swift implementation.
///
/// Pure skills (time, calc, Q&A stubs) run in-process. Effectful skills call
/// the injected ``SystemSkillExecutor``. `correct_that` needs an injected
/// ``DictionaryRecording`` (nil outside the composition root / most tests).
/// The clock is injectable so time tests can freeze `now`.
public struct BuiltinSkillRouter: BuiltinSkillExecutor {
    private let system: any SystemSkillExecutor
    private let dictionary: (any DictionaryRecording)?
    private let now: @Sendable () -> Date

    public init(
        system: any SystemSkillExecutor,
        dictionary: (any DictionaryRecording)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.system = system
        self.dictionary = dictionary
        self.now = now
    }

    public func execute(skillID: String, parameters: JSONValue) async throws -> SkillResult {
        if let pure = try pureResult(skillID: skillID, parameters: parameters) {
            return pure
        }
        return try await effectfulResult(skillID: skillID, parameters: parameters)
    }

    private func pureResult(skillID: String, parameters: JSONValue) throws -> SkillResult? {
        switch skillID {
        case "current_time":
            return try CurrentTimeSkill.run(parameters: parameters, now: now())
        case "calculate":
            return try CalculateSkill.run(parameters: parameters)
        case "unit_conversion":
            return try UnitConversionSkill.run(parameters: parameters)
        case "general_qa":
            return GeneralQASkill.run()
        case "screen_qa":
            return ScreenQASkill.run()
        default:
            return nil
        }
    }

    private func effectfulResult(
        skillID: String,
        parameters: JSONValue
    ) async throws -> SkillResult {
        switch skillID {
        case "open_application":
            return try await OpenApplicationSkill.run(parameters: parameters, system: system)
        case "quit_application":
            return try await QuitApplicationSkill.run(parameters: parameters, system: system)
        case "set_timer":
            return try await SetTimerSkill.run(parameters: parameters, system: system)
        case "media_control":
            return try await MediaControlSkill.run(parameters: parameters, system: system)
        case "take_screenshot":
            return try await TakeScreenshotSkill.run(parameters: parameters, system: system)
        case "correct_that":
            guard let dictionary else {
                throw SkillExecutionError.dictionaryUnavailable
            }
            return try await CorrectThatSkill.run(parameters: parameters, dictionary: dictionary)
        default:
            throw SkillExecutionError.unknownSkill(skillID)
        }
    }
}
