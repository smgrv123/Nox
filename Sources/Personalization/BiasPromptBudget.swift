import Foundation

/// Rank + greedy fill for the Whisper bias prompt (LLD §4.5D). Adds the next term
/// only when the comma-joined result still tokenizes at or under `tokenBudget`.
public enum BiasPromptBudget {

    public static func score(
        occurrenceCount: Int,
        lastUsedAt: Date,
        now: Date,
        halfLifeDays: Double
    ) -> Double {
        Double(occurrenceCount)
            * RecencyWeight.weight(lastUsedAt: lastUsedAt, now: now, halfLifeDays: halfLifeDays)
    }

    /// Score descending, `correctTerm` ascending. Does not filter `promoted`.
    public static func rankedEntries(
        _ entries: [DictionaryEntry],
        now: Date,
        halfLifeDays: Double
    ) -> [DictionaryEntry] {
        entries
            .map { entry in
                (
                    entry: entry,
                    score: score(
                        occurrenceCount: entry.occurrenceCount,
                        lastUsedAt: entry.lastUsedAt,
                        now: now,
                        halfLifeDays: halfLifeDays)
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.correctTerm < rhs.entry.correctTerm
            }
            .map(\.entry)
    }

    public static func rankedCorrectTerms(
        _ entries: [DictionaryEntry],
        now: Date,
        halfLifeDays: Double
    ) -> [String] {
        rankedEntries(entries, now: now, halfLifeDays: halfLifeDays).map(\.correctTerm)
    }

    /// Append `terms` in order onto `chosen`, stopping before the joined string would
    /// exceed `tokenBudget`.
    public static func append(
        _ terms: [String],
        onto chosen: [String],
        counter: any TokenCounting,
        tokenBudget: Int
    ) -> [String] {
        var result = chosen
        for term in terms where !term.isEmpty {
            let candidate = (result + [term]).joined(separator: ", ")
            if counter.tokenCount(candidate) > tokenBudget { break }
            result.append(term)
        }
        return result
    }
}
