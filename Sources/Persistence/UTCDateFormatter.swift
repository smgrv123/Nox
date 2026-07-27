import Foundation

/// Shared builder for the UTC/POSIX `DateFormatter`s used for on-disk file names
/// (day-partitioned history files, corrupt-settings backup stamps): fixed
/// `en_US_POSIX` locale + `UTC` time zone, with an injected `dateFormat` so each
/// caller keeps its own on-disk shape. `Timestamp.swift`'s log/history timestamp
/// uses `ISO8601DateFormatter` instead — a different class with no `locale` or
/// `calendar` — so it is intentionally not routed through this factory.
public enum UTCDateFormatter {

    /// Build a `DateFormatter` fixed to `en_US_POSIX` + UTC with the given format.
    /// Pass `calendar` only when the caller needs a specific calendar identity
    /// (e.g. `StorageLayout`'s ISO-8601 day boundary); omitted otherwise.
    public static func make(dateFormat: String, calendar: Calendar? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        if let calendar {
            formatter.calendar = calendar
        }
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = dateFormat
        return formatter
    }
}
