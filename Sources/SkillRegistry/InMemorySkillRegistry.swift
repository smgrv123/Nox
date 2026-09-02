import SkillManifest

/// In-memory ``SkillRegistering`` constructed from a list of manifests.
///
/// Invalid manifests (those that fail ``ManifestValidation``) and disabled
/// manifests are dropped — they never crash the registry.
public actor InMemorySkillRegistry: SkillRegistering {
    private let enabledValid: [Manifest]

    public init(manifests: [Manifest]) {
        self.enabledValid =
            manifests
            .filter { $0.enabled && ManifestValidation.validate($0).isEmpty }
            .sorted { $0.id < $1.id }
    }

    public var skills: [Manifest] {
        enabledValid
    }

    public func manifest(for skillID: String) -> Manifest? {
        enabledValid.first { $0.id == skillID }
    }

    public func routerGrammar() -> String {
        GBNFGrammarAssembler.assemble(from: enabledValid)
    }

    public func routerPromptSkillCatalog() -> String {
        RouterPromptCatalog.render(from: enabledValid)
    }

    public func validate(
        parameters: JSONValue,
        for skillID: String
    ) -> Result<Void, ParameterValidationError> {
        guard let manifest = enabledValid.first(where: { $0.id == skillID }) else {
            return .failure(.unknownSkillID(skillID))
        }
        return ParameterValidator.validate(parameters: parameters, against: manifest.parameters)
    }
}
