import AideCore
import Foundation
import LLMRuntime

/// Cleanup-prompt prefill: warms llama-server's prefix KV cache while the user is still
/// speaking, so the real cleanup call later pays only for the transcript tail, not the
/// ~480 static boilerplate tokens ahead of it.
///
/// Fires at hotkey key-down (`DictationDriver.begin(mode:)`) rather than at Pre-Gate
/// pass: capture is the only idle window in the whole flow — Whisper doesn't run until
/// the key is released, so the sidecar would otherwise sit unused for the entire
/// utterance. By the time the real `runDictationCleanup` call lands, llama.cpp has
/// already evaluated (and cached) everything up to the transcript.
///
/// This is a pure latency optimization with no user-visible effect either way: every
/// error is swallowed, and nothing here may ever delay or block capture.
extension DictationDriver {

    /// The closures `firePrefill` needs, bundled so the call across the file boundary
    /// stays under SwiftLint's `function_parameter_count` warning threshold — the five
    /// stored closures `DictationDriver` already has for cleanup would otherwise be five
    /// separate parameters on top of `llm` itself.
    struct PrefillContext {
        let llm: any LLMClient
        let resolveEndpoint: @Sendable () async throws -> LLMEndpoint
        let tonePreset: @Sendable () -> TonePreset
        let sidecarReadiness: @Sendable () async -> SidecarReadiness
        let dictionarySubstitutions: @Sendable () async -> String
    }

    /// Sends the static half of the cleanup prompt (`rawTranscript: ""`) to the sidecar
    /// so its KV cache is warm by the time the real cleanup request arrives.
    ///
    /// Gates on exactly `.ready` (`SidecarReadinessPolicy.decide(...) == .proceed`) —
    /// never `.waitUpTo`, and never calls `awaitSidecarReady` — because prefill is purely
    /// opportunistic: it must never make capture wait on a sidecar that isn't already up.
    /// A launching or unavailable sidecar just means no prefill this turn; the real
    /// cleanup call still runs its own full readiness handling later.
    ///
    /// `maxTokens: 1` because the goal is to make llama.cpp evaluate and cache the
    /// prompt, not to produce an answer — anything generated here is discarded.
    ///
    /// Crucial invariant: the prompt built here must remain a byte-for-byte strict
    /// prefix of the real cleanup prompt (`CleanupPromptBuilder.build` appends the
    /// transcript last, so `rawTranscript: ""` yields exactly that prefix). If a future
    /// change to `CleanupPromptBuilder` moves the transcript anywhere but the end, the
    /// prefix relationship breaks, llama.cpp's cache silently misses, and this whole
    /// mechanism becomes a wasted extra request rather than a speedup.
    static func firePrefill(_ context: PrefillContext) async {
        guard SidecarReadinessPolicy.decide(await context.sidecarReadiness()) == .proceed else {
            return
        }
        guard let endpoint = try? await context.resolveEndpoint() else { return }
        guard endpoint.isLocal else { return }

        let substitutions = await context.dictionarySubstitutions()
        let prompt = CleanupPromptBuilder.build(
            tone: context.tonePreset(),
            substitutions: substitutions,
            rawTranscript: "")

        // Mirrors `dictationCleanupSampling`'s shape but with `maxTokens: 1` — duplicated
        // rather than sharing that file-private constant, since only the token cap
        // differs and widening its access isn't warranted for one call site.
        let prefillSampling = SamplingParams(
            temperature: 0.2, topP: 1.0, maxTokens: 1, topLogprobs: 0, disableThinking: true)

        _ = try? await context.llm.chat(
            system: CleanupPromptBuilder.system,
            messages: [ChatMessage(role: .user, content: prompt)],
            params: prefillSampling,
            endpoint: endpoint,
            stream: false)
    }
}
