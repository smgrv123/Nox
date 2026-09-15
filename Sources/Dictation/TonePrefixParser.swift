import Foundation

/// Strips a leading `"<preset> tone:"` voice prefix (case-insensitive) so the
/// remainder can be cleaned/inserted and the preset can override Settings for this
/// utterance only (LLD §4.6; P5a Phase 4).
public struct TonePrefixParser {

    /// Match a leading tone prefix. Mid-sentence mentions of `"… tone:"` do not
    /// trigger. Returns `(nil, original)` when there is no prefix.
    public func parse(_ transcript: String) -> (preset: TonePreset?, remainder: String) {
        let haystack = String(transcript.drop(while: { $0.isWhitespace }))
        guard let match = Self.matchLeadingPrefix(haystack) else {
            return (nil, transcript)
        }
        return match
    }

    /// Tokens ordered so `"as-is"` / `"as is"` are distinct; each is followed by
    /// `\s*tone\s*:` (optional space before `tone` and before the colon).
    private static let tokens: [(String, TonePreset)] = [
        ("as-is", .asIs),
        ("as is", .asIs),
        ("professional", .professional),
        ("casual", .casual),
        ("concise", .concise),
    ]

    private static func matchLeadingPrefix(_ haystack: String) -> (preset: TonePreset, remainder: String)? {
        let lowered = haystack.lowercased()
        for (token, preset) in tokens {
            guard lowered.hasPrefix(token) else { continue }
            var rest = haystack.dropFirst(token.count)
            rest = rest.drop(while: { $0.isWhitespace })
            let restLower = rest.lowercased()
            guard restLower.hasPrefix("tone") else { continue }
            rest = rest.dropFirst(4)
            rest = rest.drop(while: { $0.isWhitespace })
            guard rest.hasPrefix(":") else { continue }
            rest = rest.dropFirst()
            rest = rest.drop(while: { $0.isWhitespace })
            return (preset, String(rest))
        }
        return nil
    }
}
