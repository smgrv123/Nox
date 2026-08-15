import Foundation

/// The result of a grammar-constrained `LLMClient.routeComplete` call (docs/05-lld.md
/// §3.3; plan Phase 3; User Stories 3, 4, 19).
///
/// **Deliberate deviation from the LLD §3.3 shape:** the LLD also names a `decision:
/// RouterDecision` field ("parsed"). `RouterDecision` (LLD §3.1) is a `SkillRegistry`
/// type, and Router Contract v2 — the schema that gives `raw`'s JSON any structure to
/// parse in the first place — is explicitly P4 scope (PRD "Out of Scope": "Router
/// Contract v2, GBNF grammar generation... — P4. P2b's client accepts an already-built
/// grammar and requests logprobs; it does not generate or interpret either."). P2b's
/// `routeComplete` is **passthrough only**: it forwards the caller-supplied grammar
/// unmodified and never inspects `raw`'s contents, so there is nothing correct to put in
/// a `decision` field yet. Rather than fabricate a placeholder `RouterDecision` this
/// phase doesn't use, `RouterCompletion` narrows to exactly what `routeComplete` actually
/// produces — `raw` + `tokenLogprobs` — mirroring the same "minimal placeholder, extend
/// later" precedent `LLMEndpoint.apiKeyRef: String?` set in Phase 2 for `KeychainRef?`.
/// P4 adds `decision` (or parses `raw` itself) once Router Contract v2 exists.
public struct RouterCompletion: Equatable, Sendable {
    /// The raw, grammar-constrained completion text — unparsed and unvalidated.
    public let raw: String
    /// Per-token logprobs aligned to `raw`'s UTF-8 bytes, in generation order.
    public let tokenLogprobs: [TokenLogprob]

    public init(raw: String, tokenLogprobs: [TokenLogprob]) {
        self.raw = raw
        self.tokenLogprobs = tokenLogprobs
    }
}
