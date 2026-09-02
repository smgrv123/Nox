import AideCore
import SkillManifest
import XCTest

@testable import SkillRegistry

final class InMemorySkillRegistryTests: XCTestCase {

    func testFiltersInvalidManifestsAndRetainsValidOnes() async {
        let valid = makeManifest(id: "open_application")
        let invalid = makeManifest(id: "BAD")
        let registry = InMemorySkillRegistry(manifests: [valid, invalid])

        let skills = await registry.skills

        XCTAssertEqual(skills.map(\.id), ["open_application"])
    }

    func testExcludesDisabledManifests() async {
        let enabled = makeManifest(id: "open_application", enabled: true)
        let disabled = makeManifest(id: "set_timer", enabled: false)
        let registry = InMemorySkillRegistry(manifests: [enabled, disabled])

        let skills = await registry.skills

        XCTAssertEqual(skills.map(\.id), ["open_application"])
    }

    func testSkillsAreSortedByIDRegardlessOfInputOrder() async {
        let zebra = makeManifest(id: "zebra_skill")
        let alpha = makeManifest(id: "alpha_skill")
        let registry = InMemorySkillRegistry(manifests: [zebra, alpha])

        let skills = await registry.skills

        XCTAssertEqual(skills.map(\.id), ["alpha_skill", "zebra_skill"])
    }

    func testManifestLookupReturnsEnabledSkill() async {
        let manifest = makeManifest(id: "open_application")
        let registry = InMemorySkillRegistry(manifests: [manifest])

        let found = await registry.manifest(for: "open_application")

        XCTAssertEqual(found?.id, "open_application")
    }

    func testManifestLookupReturnsNilForUnknownOrDisabledID() async {
        let enabled = makeManifest(id: "open_application")
        let disabled = makeManifest(id: "set_timer", enabled: false)
        let registry = InMemorySkillRegistry(manifests: [enabled, disabled])

        let unknown = await registry.manifest(for: "not_a_skill")
        let skipped = await registry.manifest(for: "set_timer")

        XCTAssertNil(unknown)
        XCTAssertNil(skipped)
    }
}

// MARK: - Fixtures

func makeManifest(
    id: String,
    description: String = "A test skill for unit testing purposes.",
    utteranceExamples: [String] = [],
    parameters: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([]),
        "properties": .object([:]),
    ]),
    enabled: Bool = true
) -> Manifest {
    Manifest(
        schemaVersion: 1,
        id: id,
        kind: .builtin,
        displayName: id,
        description: description,
        utteranceExamples: utteranceExamples,
        parameters: parameters,
        permissions: ManifestPermissions(),
        schedule: nil,
        riskTier: .low,
        enabled: enabled,
        scriptRef: nil,
        scriptSha256: nil,
        timeoutSeconds: 60,
        failureState: FailureState(),
        createdAt: nil,
        updatedAt: nil,
        generatedBy: .builtin
    )
}

func objectSchema(
    required: [String],
    properties: [String: JSONValue],
    additionalProperties: Bool? = false
) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("object"),
        "required": .array(required.map { .string($0) }),
        "properties": .object(properties),
    ]
    if let additionalProperties {
        schema["additionalProperties"] = .bool(additionalProperties)
    }
    return .object(schema)
}

func stringType() -> JSONValue {
    .object(["type": .string("string")])
}

func integerType() -> JSONValue {
    .object(["type": .string("integer")])
}
