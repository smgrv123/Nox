import Foundation

/// Strips wrapping quotes and a fixed list of model preambles from a cleanup
/// completion (LLD §4.6 step 4). Does not try to detect added facts.
public enum CleanupResponseSanitizer {
    private static let preambles = [
        "Here is the cleaned text:",
        "Here's the cleaned text:",
        "Cleaned text:",
        "Sure,",
        "Certainly,",
    ]

    public static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripWrappingQuotes(text)
        text = stripPreamble(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        if text.hasPrefix("\"\"\""), text.hasSuffix("\"\"\""), text.count >= 6 {
            let start = text.index(text.startIndex, offsetBy: 3)
            let end = text.index(text.endIndex, offsetBy: -3)
            return String(text[start..<end])
        }
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            let start = text.index(after: text.startIndex)
            let end = text.index(before: text.endIndex)
            return String(text[start..<end])
        }
        return text
    }

    private static func stripPreamble(_ text: String) -> String {
        let lowered = text.lowercased()
        for preamble in preambles {
            let needle = preamble.lowercased()
            guard lowered.hasPrefix(needle) else { continue }
            return String(text.dropFirst(preamble.count))
        }
        return text
    }
}
