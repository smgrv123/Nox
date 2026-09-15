import Foundation

/// Hard-cap eviction (LLD §4.5C). Auto-source entries go first (oldest
/// `lastUsedAt` first); only then the oldest explicit. A missing/sentinel
/// `lastUsedAt` of `.distantPast` is treated as oldest.
public enum MRUEviction {

    public static func evict(_ entries: [DictionaryEntry], cap: Int) -> [DictionaryEntry] {
        let limit = max(0, cap)
        guard entries.count > limit else { return entries }

        var remaining = entries
        while remaining.count > limit {
            let autoIndices = remaining.indices.filter { remaining[$0].source == .auto }
            let victimIndex: Int
            if let oldestAuto = autoIndices.min(by: { remaining[$0].lastUsedAt < remaining[$1].lastUsedAt }) {
                victimIndex = oldestAuto
            } else if let oldest = remaining.indices.min(by: {
                remaining[$0].lastUsedAt < remaining[$1].lastUsedAt
            }) {
                victimIndex = oldest
            } else {
                break
            }
            remaining.remove(at: victimIndex)
        }
        return remaining
    }
}
