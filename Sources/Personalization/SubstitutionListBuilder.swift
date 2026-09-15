import Foundation

/// Cleanup-prompt substitution list (LLD §4.5E): ranked promoted
/// `mishearing -> correct` pairs, capped at `BudgetConfig.substitutionTopN`.
/// Empty input renders `none.` so P5a's `CleanupPromptBuilder` slot is never blank.
public enum SubstitutionListBuilder {

    public static func build(
        promotedEntries: [DictionaryEntry],
        config: BudgetConfig = .default,
        now: Date = Date()
    ) -> String {
        let ranked = BiasPromptBudget.rankedEntries(
            promotedEntries.filter(\.promoted),
            now: now,
            halfLifeDays: config.recencyHalfLifeDays)

        var lines: [String] = []
        let cap = max(0, config.substitutionTopN)
        guard cap > 0 else { return "none." }
        outer: for entry in ranked {
            for mishearing in entry.mishearings where !mishearing.isEmpty {
                lines.append("`\(mishearing)` -> `\(entry.correctTerm)`")
                if lines.count >= cap { break outer }
            }
        }
        return lines.isEmpty ? "none." : lines.joined(separator: "\n")
    }
}
