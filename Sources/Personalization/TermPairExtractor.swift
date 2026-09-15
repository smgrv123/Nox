import Foundation

/// Explicit "correct that: X should be Y" pair extraction (LLD §4.5A). Trims both
/// sides and rejects empty or identical (case-insensitive) pairs. The auto-diff
/// path is architected elsewhere and is not called in v1.
public enum TermPairExtractor {

    public static func extractExplicit(mishearing: String, correct: String) -> TermPair? {
        let heard = mishearing.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = correct.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !term.isEmpty else { return nil }
        guard heard.caseInsensitiveCompare(term) != .orderedSame else { return nil }
        return TermPair(mishearing: heard, correctTerm: term)
    }
}
