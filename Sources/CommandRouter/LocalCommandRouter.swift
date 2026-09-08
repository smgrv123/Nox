import Foundation
import LLMRuntime

/// Local-only ``Routing`` conformer: calls `LLMClient.routeComplete` on the
/// caller-supplied endpoint (never a cloud fallback), parses Contract v2, and
/// derives ``RoutingConfidence``. Catalog and grammar are injected strings —
/// this module does not depend on SkillRegistry.
public struct LocalCommandRouter: Routing {

    private let client: any LLMClient
    private let skillCatalog: String
    private let grammar: String
    private let sessionContext: String
    private let promptBuilder: RouterPromptBuilder

    /// - Parameters:
    ///   - client: The LLM seam (`MockLLMClient` in tests; never `InferenceClient` here).
    ///   - skillCatalog: Text substituted for `{{SKILL_CATALOG}}`.
    ///   - grammar: GBNF forwarded unmodified to `routeComplete`.
    ///   - sessionContext: `{{SESSION_CONTEXT}}`; empty until P6.
    ///   - promptBuilder: Builds the LLD §6.1 system prompt.
    public init(
        client: any LLMClient,
        skillCatalog: String,
        grammar: String,
        sessionContext: String = "",
        promptBuilder: RouterPromptBuilder = RouterPromptBuilder()
    ) {
        self.client = client
        self.skillCatalog = skillCatalog
        self.grammar = grammar
        self.sessionContext = sessionContext
        self.promptBuilder = promptBuilder
    }

    public func route(
        transcript: String,
        whisperAvgLogprob: Float,
        endpoint: LLMEndpoint
    ) async throws -> RoutedIntent {
        // Accepted for the calibration record; Phase 3 does not gate on it.
        _ = whisperAvgLogprob
        guard endpoint.isLocal else {
            throw RoutingError.cloudEndpointRejected
        }

        let system = promptBuilder.build(
            skillCatalog: skillCatalog,
            transcript: transcript,
            sessionContext: sessionContext)
        let completion = try await client.routeComplete(
            system: system,
            user: transcript,
            grammar: grammar,
            endpoint: endpoint)
        let decision = try RouterContractParser.parse(completion)
        let confidence = try RoutingConfidenceDeriver.derive(from: completion)
        return RoutedIntent(decision: decision, confidence: confidence)
    }
}
