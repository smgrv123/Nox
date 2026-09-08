import Foundation

/// Assembles the Router system prompt from the LLD §6.1 template.
/// Substitutes `{{SKILL_CATALOG}}`, `{{SESSION_CONTEXT}}`, and `{{TRANSCRIPT}}`.
/// Session context is an empty string until P6 supplies real history.
public struct RouterPromptBuilder: Sendable {

    /// Literal LLD §6.1 template. Placeholders are substituted by ``build``.
    public static let template = """
        You are Aide's router. You do not chat and you do not execute anything.
        Your only job: read the user's utterance (and recent context) and emit ONE JSON object
        that selects a registered skill and its parameters.

        You MUST emit exactly this shape (enforced by grammar):
          { "intent": <short restatement>, "skill_id": <registered id | null>, "parameters": { ... } }

        Rules:
        - Write "intent" first: a short, plain restatement of what the user wants.
        - Choose "skill_id" ONLY from the registered skills below. If nothing fits, use null.
        - Do NOT invent skills, parameters, or values. Do NOT guess when unsure — prefer null.
        - Fill "parameters" strictly per the chosen skill's schema.
        - General questions ("who is…", "explain…", "what's the capital of…") route to "general_qa".
        - Treat the conversation context as continuation unless it is clearly a new command.

        Registered skills:
        {{SKILL_CATALOG}}   <!-- generated: id, description, parameter schema, example utterances -->

        Recent context (most recent last):
        {{SESSION_CONTEXT}}

        User utterance:
        {{TRANSCRIPT}}
        """

    public init() {}

    /// Substitute the three LLD §6.1 placeholders. `sessionContext` defaults to
    /// empty (P6 will fill this later).
    public func build(
        skillCatalog: String,
        transcript: String,
        sessionContext: String = ""
    ) -> String {
        RouterPromptBuilder.template
            .replacingOccurrences(of: "{{SKILL_CATALOG}}", with: skillCatalog)
            .replacingOccurrences(of: "{{SESSION_CONTEXT}}", with: sessionContext)
            .replacingOccurrences(of: "{{TRANSCRIPT}}", with: transcript)
    }
}
