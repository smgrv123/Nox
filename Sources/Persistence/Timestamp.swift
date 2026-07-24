import Foundation

/// The single timestamp format shared by `app.log` and every JSONL log: ISO-8601
/// in UTC with millisecond precision (e.g. `2026-07-24T09:12:04.221Z`), matching
/// the wire examples in docs/05-lld.md §2.6. Kept in one place so logs and history
/// never drift apart.
enum Timestamp {

    /// Concurrent formatting is safe on `ISO8601DateFormatter`; a single shared
    /// instance mirrors `DangerousCommandScanner`'s static-rule idiom.
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}
