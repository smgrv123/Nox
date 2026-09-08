import Foundation

/// Dictation tone-cleanup presets (LLD §4.6). Default is `asIs` — fix grammar and
/// filler, keep the user's wording. Voice-prefix override and Settings land in Phase 4.
public enum TonePreset: String, Equatable, Sendable, Codable {
    case asIs = "as_is"
    case professional
    case casual
    case concise

    /// Instruction block injected into the LLD §6.3 cleanup prompt.
    public var instruction: String {
        switch self {
        case .asIs:
            return """
                Fix grammar, punctuation, remove filler ("um", "you know", false starts). \
                Preserve the user's wording, voice, and register. No rephrasing.
                """
        case .professional:
            return """
                As-is cleanup + neutral/formal register, expand contractions, complete sentences, \
                remove slang. Do not add content.
                """
        case .casual:
            return """
                As-is cleanup + relaxed, conversational tone; contractions fine; keep it natural.
                """
        case .concise:
            return """
                As-is cleanup + tighten aggressively: remove redundancy, shorten, keep meaning. \
                Never drop facts.
                """
        }
    }
}
