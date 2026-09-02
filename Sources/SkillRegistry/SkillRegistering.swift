import SkillManifest

/// DI seam for the Skill Registry (LLD §3.1).
///
/// Consumers (Router, Dispatcher) depend on this protocol — never
/// ``InMemorySkillRegistry`` — so tests can substitute a stub without
/// touching grammar assembly or validation.
public protocol SkillRegistering: Actor {
    /// Enabled, valid manifests only, sorted by `id`.
    var skills: [Manifest] { get async }

    func manifest(for skillID: String) async -> Manifest?

    /// GBNF text constraining Router Contract v2 (LLD §2.2.2 / §4.4).
    func routerGrammar() async -> String

    /// Skill catalog injected into the router system prompt as `{{SKILL_CATALOG}}`.
    func routerPromptSkillCatalog() async -> String

    /// Hard-rejection validation of router-emitted parameters against the skill schema.
    func validate(
        parameters: JSONValue,
        for skillID: String
    ) async -> Result<Void, ParameterValidationError>
}
