import SpeechToText

/// Tests-only ``TokenCounting`` stand-in. Production never constructs this type;
/// the live conformer is `WhisperTokenCounter` wrapping `whisper_token_count`.
struct FakeCounter: TokenCounting {
    func tokenCount(_ text: String) -> Int { max(1, text.count / 4) }
}
