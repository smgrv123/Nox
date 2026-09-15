import AideCore
import Foundation

/// Dictation tone-cleanup presets (LLD §4.6). Default is `asIs` — fix grammar and
/// filler, keep the user's wording. Defined once in `AideCore` and shared with
/// `Settings.TonePreset`; this module adds the `instruction` computed property used
/// by `CleanupPromptBuilder`.
public typealias TonePreset = AideCore.TonePreset

extension TonePreset {
    /// Instruction block injected into the LLD §6.3 cleanup prompt.
    public var instruction: String {
        switch self {
        case .asIs:
            return """
                Delete every filler word and disfluency — "um", "uh", "like", "you know", false \
                starts ("I was I think" -> "I think"), and accidental word repeats ("the the" -> \
                "the") — this deletion is mandatory in every preset, including this one. \
                Punctuate fully and always, no matter how long or run-on the transcript is: split \
                it into separate sentences wherever a natural sentence boundary falls, give each \
                sentence terminal punctuation (. ? !), capitalize only the first letter of each \
                sentence (not every word), and add obvious intra-sentence commas — this is \
                mandatory in every preset, including this one, and is NOT a change to the user's \
                wording. Otherwise: Preserve the user's wording, voice, and register exactly as \
                spoken — do not rephrase, do not substitute synonyms, do not reorder words within \
                a sentence, do not add or remove content words.
                """
        case .professional:
            return """
                As-is cleanup + neutral/formal register, expand contractions, complete sentences, \
                remove slang. Do not add content.
                """
        case .casual:
            return """
                Step 1, always: delete every filler word and disfluency — "um", "uh", "like", \
                "you know", false starts, and accidental word repeats ("the the" -> "the"). This \
                deletion is mandatory. Step 2, always, no matter how long or run-on the \
                transcript is: punctuate fully — split it into separate sentences wherever a \
                natural sentence boundary falls, give each sentence terminal punctuation \
                (. ? !), capitalize only the first letter of each sentence (not every word), and \
                add obvious intra-sentence commas. This is mandatory and is NOT a change to \
                wording. Step 3: keep a relaxed, conversational tone; contractions are fine; keep \
                it natural. Don't formalize the wording beyond removing filler and adding \
                punctuation.
                """
        case .concise:
            return """
                As-is cleanup + tighten aggressively: remove redundancy, shorten, keep meaning. \
                Never drop facts.
                """
        }
    }
}
