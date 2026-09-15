import Foundation

/// Builds the merged Whisper `initialPrompt`: ranked dictionary `correct_term`s first,
/// then leftover-budget extra phrases (installed app names), joined with `", "`.
public struct BiasPromptBuilder: Sendable {

    public init() {}

    public func build(
        promotedEntries: [DictionaryEntry],
        extraPhrases: [String],
        counter: any TokenCounting,
        config: BudgetConfig = .default,
        now: Date = Date()
    ) -> String? {
        let dictionaryTerms = BiasPromptBudget.rankedCorrectTerms(
            promotedEntries,
            now: now,
            halfLifeDays: config.recencyHalfLifeDays)
        let afterDictionary = BiasPromptBudget.append(
            dictionaryTerms,
            onto: [],
            counter: counter,
            tokenBudget: config.tokenBudget)
        let cappedExtraPhrases = Array(extraPhrases.prefix(config.appNameCap))
        let filled = BiasPromptBudget.append(
            cappedExtraPhrases,
            onto: afterDictionary,
            counter: counter,
            tokenBudget: config.tokenBudget)
        let prompt = filled.joined(separator: ", ")
        return prompt.isEmpty ? nil : prompt
    }
}
