import Foundation

/// Promotion threshold (LLD §4.5B). Explicit entries are consumed immediately;
/// auto entries wait until `occurrenceCount` reaches `promoteMin`.
public enum PromotionPolicy {

    public static func isPromoted(
        source: DictionaryEntry.Source,
        occurrenceCount: Int,
        promoteMin: Int
    ) -> Bool {
        switch source {
        case .explicit:
            return true
        case .auto:
            return occurrenceCount >= promoteMin
        }
    }

    public static func withPromotion(_ entry: DictionaryEntry, promoteMin: Int) -> DictionaryEntry {
        var next = entry
        next.promoted = isPromoted(
            source: entry.source,
            occurrenceCount: entry.occurrenceCount,
            promoteMin: promoteMin)
        return next
    }
}
