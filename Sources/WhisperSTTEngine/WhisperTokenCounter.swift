import Foundation
import SpeechToText
import whisper

/// Production ``TokenCounting`` wrapping **`whisper_token_count`** (whisper.h).
///
/// Not `whisper_tokenize`: `whisper_token_count` is the one-call fit for
/// `TokenCounting.tokenCount`. Use only inside ``WhisperSTTEngine/withTokenCounter(_:)``
/// — never escape the counter; the C API needs the warm `whisper_context` and is
/// not thread-safe with ``WhisperSTTEngine/transcribe``.
///
/// `@unchecked Sendable` is required by ``TokenCounting`` (`Sendable`); isolation
/// comes from `withTokenCounter`, not from this conformance.
public struct WhisperTokenCounter: TokenCounting, @unchecked Sendable {

    private let context: OpaquePointer

    init(context: OpaquePointer) {
        self.context = context
    }

    public func tokenCount(_ text: String) -> Int {
        let count = text.withCString { whisper_token_count(context, $0) }
        return Self.clampedTokenCount(Int(count))
    }

    /// Maps a raw C `whisper_token_count` result. A negative count is a C-side
    /// failure and must exceed any token budget so greedy fill stops (`count >
    /// tokenBudget`); clamping it to `0` would let the candidate through.
    static func clampedTokenCount(_ count: Int) -> Int {
        count < 0 ? .max : count
    }
}
