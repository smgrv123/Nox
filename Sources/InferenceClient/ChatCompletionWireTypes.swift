import Foundation

// The OpenAI-compatible `/v1/chat/completions` wire shapes (docs/05-lld.md §3.3;
// docs/native-deps.md's llama-server section; plan Phase 3) — verified against the real
// bundled `llama-server` binary (`b10332`) during this phase's development, both
// non-streamed and SSE-streamed, both with and without a passthrough `grammar`. Kept
// `internal` (not `private`) so `InferenceClient.swift` can use them directly while
// staying out of the public `LLMClient` seam — callers only ever see `LLMRuntime`'s
// protocol-level types (`ChatMessage`, `TokenLogprob`, …), never these wire DTOs.

// MARK: - Request

/// `grammar` is llama.cpp's GBNF-passthrough extension to the OpenAI shape — `nil` omits
/// the key entirely (the free-form `chat` path); `routeComplete` always supplies it,
/// even when the caller's grammar string is empty, so "passthrough unmodified" holds
/// exactly (an empty string is still encoded, not silently dropped).
struct ChatCompletionRequestBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let topP: Double
    let maxTokens: Int?
    let stream: Bool
    let logprobs: Bool
    let topLogprobs: Int?
    let grammar: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, logprobs, grammar
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case topLogprobs = "top_logprobs"
    }
}

// MARK: - Response (shared logprobs shape)

/// One entry of a `logprobs.content` array — present on both the non-streamed response
/// and each SSE chunk. `bytes` is the token's raw UTF-8 bytes; llama-server always sends
/// it for the real completions this phase exercised, but `TokenLogprob` construction
/// falls back to `token.utf8.count` if a future build ever omits it, rather than crash.
struct TokenLogprobEntry: Decodable {
    let token: String
    let bytes: [Int]?
    let logprob: Double
}

struct LogprobsBody: Decodable {
    let content: [TokenLogprobEntry]?
}

// MARK: - Non-streamed response

struct ChatCompletionResponseBody: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
        let logprobs: LogprobsBody?
    }
    let choices: [Choice]
}

// MARK: - Streamed response (one decoded per SSE `data:` line)

struct ChatCompletionChunkBody: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta
        let logprobs: LogprobsBody?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta, logprobs
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}
