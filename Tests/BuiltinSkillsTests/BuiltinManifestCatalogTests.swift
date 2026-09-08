import AideCore
import SkillManifest
import XCTest

@testable import BuiltinSkills

final class BuiltinManifestCatalogTests: XCTestCase {

    private struct ExpectedRow {
        let riskTier: RiskTier
        let required: [String]
        let propertyTypes: [String: String]
        let requires: [String]
    }

    private let expectedCatalog: [String: ExpectedRow] = [
        "current_time": ExpectedRow(
            riskTier: .low,
            required: [],
            propertyTypes: ["timezone": "string"],
            requires: []
        ),
        "calculate": ExpectedRow(
            riskTier: .low,
            required: ["expression"],
            propertyTypes: ["expression": "string"],
            requires: []
        ),
        "general_qa": ExpectedRow(
            riskTier: .low,
            required: ["question"],
            propertyTypes: ["question": "string"],
            requires: []
        ),
        "screen_qa": ExpectedRow(
            riskTier: .low,
            required: ["question"],
            propertyTypes: ["question": "string"],
            requires: ["screen_recording"]
        ),
        "open_application": ExpectedRow(
            riskTier: .confirm,
            required: ["app_name"],
            propertyTypes: ["app_name": "string"],
            requires: []
        ),
        "quit_application": ExpectedRow(
            riskTier: .confirm,
            required: ["app_name"],
            propertyTypes: ["app_name": "string"],
            requires: []
        ),
        "set_timer": ExpectedRow(
            riskTier: .confirm,
            required: ["duration_seconds"],
            propertyTypes: ["duration_seconds": "integer", "label": "string"],
            requires: []
        ),
        "media_control": ExpectedRow(
            riskTier: .confirm,
            required: ["action"],
            propertyTypes: ["action": "string"],
            requires: []
        ),
        "take_screenshot": ExpectedRow(
            riskTier: .alwaysConfirm,
            required: [],
            propertyTypes: ["region": "string"],
            requires: ["screen_recording"]
        ),
        "unit_conversion": ExpectedRow(
            riskTier: .low,
            required: ["value", "from_unit", "to_unit"],
            propertyTypes: ["value": "number", "from_unit": "string", "to_unit": "string"],
            requires: []
        ),
    ]

    func testCatalogContainsExactlyTenManifests() {
        XCTAssertEqual(BuiltinManifestCatalog.all.count, 10)
        let ids = Set(BuiltinManifestCatalog.all.map(\.id))
        XCTAssertEqual(ids, Set(expectedCatalog.keys))
    }

    func testEveryManifestPassesValidation() {
        for manifest in BuiltinManifestCatalog.all {
            let issues = ManifestValidation.validate(manifest)
            XCTAssertTrue(issues.isEmpty, "\(manifest.id) should be valid, got: \(issues)")
            XCTAssertEqual(manifest.kind, .builtin)
        }
    }

    func testRiskTiersMatchLLDTable() {
        let byID = Dictionary(uniqueKeysWithValues: BuiltinManifestCatalog.all.map { ($0.id, $0) })
        for (id, expected) in expectedCatalog {
            XCTAssertEqual(byID[id]?.riskTier, expected.riskTier, "risk tier for \(id)")
        }
    }

    func testEveryCatalogIDIsRoutableByBuiltinSkillRouter() async throws {
        let router = makeRouter()
        for manifest in BuiltinManifestCatalog.all {
            do {
                _ = try await router.execute(
                    skillID: manifest.id,
                    parameters: sampleParameters(for: manifest.id)
                )
            } catch SkillExecutionError.unknownSkill(let id) {
                XCTFail("catalog id \(id) is not a BuiltinSkillRouter case")
            }
        }
    }

    func testParameterSchemasMatchSkillExtraction() {
        let byID = Dictionary(uniqueKeysWithValues: BuiltinManifestCatalog.all.map { ($0.id, $0) })
        for id in expectedCatalog.keys.sorted() {
            guard let manifest = byID[id], let expected = expectedCatalog[id] else {
                XCTFail("missing catalog entry \(id)")
                continue
            }
            XCTAssertEqual(requiredKeys(of: manifest), expected.required, "required for \(id)")
            XCTAssertEqual(
                propertyKeys(of: manifest),
                Set(expected.propertyTypes.keys),
                "properties for \(id)"
            )
            for (name, type) in expected.propertyTypes {
                XCTAssertEqual(
                    manifest.parameters["properties"]?[name]?["type"]?.stringValue,
                    type,
                    "type of \(id).\(name)"
                )
            }
            XCTAssertEqual(manifest.permissions.requires, expected.requires, "permissions for \(id)")
        }

        XCTAssertEqual(
            enumValues(of: byID["media_control"]!, property: "action"),
            ["play", "pause", "toggle", "next", "previous"]
        )
        XCTAssertEqual(
            enumValues(of: byID["take_screenshot"]!, property: "region"),
            ["full"]
        )
    }
}

private func requiredKeys(of manifest: Manifest) -> [String] {
    manifest.parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
}

private func propertyKeys(of manifest: Manifest) -> Set<String> {
    Set((manifest.parameters["properties"]?.objectValue ?? [:]).keys)
}

private func enumValues(of manifest: Manifest, property: String) -> [String] {
    manifest.parameters["properties"]?[property]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
}

private func sampleParameters(for skillID: String) -> JSONValue {
    switch skillID {
    case "current_time":
        return objectParams(["timezone": .string("UTC")])
    case "calculate":
        return objectParams(["expression": .string("1+1")])
    case "general_qa", "screen_qa":
        return objectParams(["question": .string("what")])
    case "open_application", "quit_application":
        return objectParams(["app_name": .string("Safari")])
    case "set_timer":
        return objectParams(["duration_seconds": .int(10)])
    case "media_control":
        return objectParams(["action": .string("play")])
    case "take_screenshot":
        return objectParams(["region": .string("full")])
    case "unit_conversion":
        return objectParams([
            "value": .double(10),
            "from_unit": .string("miles"),
            "to_unit": .string("kilometers"),
        ])
    default:
        return objectParams()
    }
}
