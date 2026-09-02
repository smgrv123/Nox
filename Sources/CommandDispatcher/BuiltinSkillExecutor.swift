import SkillManifest

/// Seam for built-in skill implementations. Phase 6 supplies the real router;
/// tests inject a mock. Effectful skills stay behind this protocol so the
/// dispatcher stays headless.
public protocol BuiltinSkillExecutor: Sendable {
    func execute(skillID: String, parameters: JSONValue) async throws -> SkillResult
}
