import AideCore
import CommandDispatcher
import SkillManifest

enum CorrectThatSkill {
    static func run(
        parameters: JSONValue,
        dictionary: any DictionaryRecording
    ) async throws -> SkillResult {
        let mishearing = try ParameterReader.requiredString("mishearing", in: parameters)
        let correctTerm = try ParameterReader.requiredString("correct_term", in: parameters)
        try await dictionary.record(mishearing: mishearing, correctTerm: correctTerm)
        return SkillResult(summary: "Remembered “\(correctTerm)” (heard as “\(mishearing)”).")
    }
}
