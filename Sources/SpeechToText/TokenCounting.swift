import Foundation

/// Whisper-tokenizer seam for bias-prompt budgeting (LLD §4.5D). Production wraps
/// `whisper_token_count`; tests inject a fake. Sync by lock so budgeting stays a
/// pure greedy loop.
public protocol TokenCounting: Sendable {
    func tokenCount(_ text: String) -> Int
}
