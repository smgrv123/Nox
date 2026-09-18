import Foundation

/// Memoizes the Whisper bias `initialPrompt`, keyed on `DictionaryStore.generation()`
/// (docs/05-lld.md §4.5D.4: "Recompute lazily; cache and invalidate on dictionary
/// change"; specs/P5b-personalization-dictionary.md:83). Without this,
/// `makeBiasInitialPrompt` (`App/AppCoordinator+CommandMode.swift`) re-ranked and
/// re-tokenized the full prompt inside `WhisperSTTEngine.withTokenCounter` — an
/// O(terms²) `whisper_token_count` cost serialized on the whisper actor — before
/// every utterance, even when the dictionary had not changed since the last build.
///
/// An `actor` (rather than a plain struct) because the memoized state must survive
/// across calls from a `@Sendable () async -> String?` closure that may be invoked
/// repeatedly, and possibly concurrently, over the lifetime of a voice session.
public actor BiasPromptCache {

    private var lastGeneration: Int?
    private var lastValue: String?

    public init() {}

    /// Returns the value memoized for `generation` when it matches the generation the
    /// cache last computed for; otherwise runs `compute`, memoizes its result against
    /// `generation`, and returns that.
    ///
    /// A throw from `compute` propagates without updating the cache, so the next call
    /// for the same generation retries rather than caching a failure — this preserves
    /// the caller's existing per-call tokenizer-fallback behavior on a cache miss.
    public func value(
        forGeneration generation: Int,
        compute: () async throws -> String?
    ) async rethrows -> String? {
        if let lastGeneration, lastGeneration == generation {
            return lastValue
        }
        let computed = try await compute()
        lastGeneration = generation
        lastValue = computed
        return computed
    }
}
