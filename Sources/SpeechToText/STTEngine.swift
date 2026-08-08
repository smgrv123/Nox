import Foundation

/// Which language whisper should decode as (docs/03-architecture.md §3.2, HLD §3.2).
/// The default is `.auto` — Aide targets Hindi / code-mixed speech, so we never force
/// English (User Story 4). `.explicit` pins a specific whisper language code.
public enum LanguageHint: Equatable, Sendable {
    /// Let whisper auto-detect the language (the default path).
    case auto
    /// Force a specific whisper language code, e.g. `"en"`, `"hi"`.
    case explicit(String)

    /// The default hint: auto-detect, no forced language.
    public static let `default`: LanguageHint = .auto

    /// The whisper language code, or `nil` for auto-detect (whisper treats a `nil` /
    /// `"auto"` language as "detect").
    public var whisperCode: String? {
        switch self {
        case .auto: return nil
        case .explicit(let code): return code
        }
    }
}

/// The speech-to-text seam (docs/05-lld.md §3.2; User Story 23). whisper.cpp runs
/// **in-process, batch-on-release**: a completed utterance buffer goes in, a
/// `Transcription` (text + per-segment probability metadata) comes out. The interface
/// is *load / transcribe-a-buffer* rather than "give me a file" so a future streaming
/// mode is additive (docs/04-hld.md §3.2).
///
/// Conformers are actors: the real engine keeps a warm whisper context that must not be
/// touched concurrently, and the mock is trivially isolated. UI-facing delivery happens
/// one layer up at the `AideCore.VoiceSessionDriver` seam (main-actor `onUpdate`).
public protocol STTEngine: Actor {
    /// Lazily load the model into a warm context; idempotent — safe to call before
    /// every `transcribe`, cheap after the first.
    func ensureLoaded() async throws

    /// Batch-transcribe a completed utterance.
    ///
    /// - Parameters:
    ///   - pcm: the finished mono PCM utterance (16 kHz).
    ///   - language: `.auto` for Hindi / code-mixed (the default), else a forced code.
    ///   - initialPrompt: reserves the P5 Personalization-Dictionary bias-prompt slot
    ///     (≤224 tokens, docs/05-lld.md §4.5); **unused in P2a** — pass `nil`.
    func transcribe(
        _ pcm: PCMBuffer,
        language: LanguageHint,
        initialPrompt: String?
    ) async throws -> Transcription
}

extension STTEngine {
    /// Convenience for the default path: auto-detect language, no bias prompt
    /// (User Story 4). Callers that don't personalize decoding use this overload.
    public func transcribe(_ pcm: PCMBuffer) async throws -> Transcription {
        try await transcribe(pcm, language: .auto, initialPrompt: nil)
    }
}
