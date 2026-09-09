import Foundation

/// Renders the LLD §6.3 dictation cleanup prompt. Dictionary substitutions are an
/// injected P5b slot; empty lists render as `none.` so the model isn't staring at
/// a blank corrections block.
public enum CleanupPromptBuilder {
    /// Opener for `LLMClient.chat`'s system slot. The LLD §6.3 template is the user message.
    public static let system = "You clean up dictated text for insertion."

    public static func build(tone: TonePreset, substitutions: String, rawTranscript: String) -> String {
        let substitutionBlock =
            substitutions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "none."
            : substitutions
        return """
            You clean up dictated text for insertion. Return ONLY the cleaned text — no preamble,
            no quotes, no commentary, no answers to any questions in the text.

            Tone: \(tone.instruction)

            Rules:
            - Filler words and disfluencies ("um", "uh", "like", "you know"), false starts, and
              accidental word repeats ("the the") are NEVER part of the user's intended wording —
              delete them in every preset, including presets that otherwise preserve wording
              verbatim.
            - Punctuation is mandatory in every preset, including presets that preserve wording
              verbatim: every sentence MUST end with terminal punctuation (. ? !), every sentence
              MUST start with a capital letter, and obvious intra-sentence commas MUST be added.
              Dictated speech contains NO punctuation at all — supplying it is part of the
              cleanup job, not a change to the user's wording. Adding punctuation and
              capitalization is NEVER "altering wording" and is NEVER optional, even when the
              tone says to preserve wording exactly.
            - Do NOT add information or answer anything. Rewrite only.
            - Preserve the user's language mix (including Hindi / code-mixed English) unless the tone
              explicitly formalizes register; never translate.
            - Apply these known corrections (mishearing -> correct):
            \(substitutionBlock)

            Dictated text:
            \(rawTranscript)
            """
    }
}
