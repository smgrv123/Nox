import Foundation

/// One increment of a `chat` completion (docs/05-lld.md §3.3; plan Phase 3; User Story
/// 5). A **non-streamed** call (`stream: false`) still produces exactly one chunk —
/// `delta` holding the whole completion, `isFinal` true — so callers always consume
/// `ChatCompletionStream` the same way regardless of which wire mode actually served it;
/// only `InferenceClient`'s internals differ (one buffered HTTP response vs. an
/// SSE-driven sequence of chunks).
public struct ChatCompletionChunk: Equatable, Sendable {
    /// The incremental text this chunk adds. Empty on the terminal chunk of a stream that
    /// ends without trailing content (the common case — the last real token already
    /// carried its own delta).
    public let delta: String
    /// True on the chunk that ends the completion (the Sidecar's `finish_reason` arrived,
    /// or — for a non-streamed call — this is simply the only chunk).
    public let isFinal: Bool
    /// Per-token logprobs carried by *this* chunk, aligned to `SamplingParams.topLogprobs
    /// > 0` having been requested; empty when logprobs weren't requested or this chunk
    /// carried none. Byte ranges are cumulative across the whole stream (see
    /// `TokenLogprob`), not chunk-local.
    public let logprobs: [TokenLogprob]

    public init(delta: String, isFinal: Bool, logprobs: [TokenLogprob] = []) {
        self.delta = delta
        self.isFinal = isFinal
        self.logprobs = logprobs
    }
}

/// `LLMClient.chat`'s return type (docs/05-lld.md §3.3) — an `AsyncSequence` of
/// `ChatCompletionChunk`, whether the underlying call was streamed or not (see
/// `ChatCompletionChunk`'s doc comment). Wraps `AsyncThrowingStream` so both
/// `InferenceClient` (a live SSE read, or a single buffered chunk) and `MockLLMClient`
/// (a caller-injected, already-known chunk list) can vend the exact same public type.
public struct ChatCompletionStream: AsyncSequence, Sendable {
    public typealias Element = ChatCompletionChunk
    public typealias AsyncIterator = AsyncThrowingStream<ChatCompletionChunk, Error>.Iterator

    private let stream: AsyncThrowingStream<ChatCompletionChunk, Error>

    /// Wrap an already-constructed stream — `InferenceClient`'s live SSE path uses this,
    /// feeding the stream's continuation as bytes arrive off the wire.
    public init(stream: AsyncThrowingStream<ChatCompletionChunk, Error>) {
        self.stream = stream
    }

    /// Convenience for a fixed, already-known set of chunks — `MockLLMClient`'s
    /// deterministic conformance, and `InferenceClient`'s own non-streamed path (a single
    /// buffered HTTP response has all its chunks up front too).
    public init(chunks: [ChatCompletionChunk]) {
        self.init(
            stream: AsyncThrowingStream { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            })
    }

    public func makeAsyncIterator() -> AsyncIterator {
        stream.makeAsyncIterator()
    }
}
