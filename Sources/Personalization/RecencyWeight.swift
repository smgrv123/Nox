import Foundation

/// Recency decay for dictionary ranking: `0.5 ^ (ageDays / halfLifeDays)`.
public enum RecencyWeight {

    public static func weight(lastUsedAt: Date, now: Date, halfLifeDays: Double) -> Double {
        guard halfLifeDays > 0 else { return 1 }
        let ageDays = now.timeIntervalSince(lastUsedAt) / 86_400
        return pow(0.5, ageDays / halfLifeDays)
    }
}
