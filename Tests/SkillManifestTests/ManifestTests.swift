import AideCore
import Foundation
import XCTest

@testable import SkillManifest

final class ManifestTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    // MARK: - Builtin manifest round-trip

    func testBuiltinManifestRoundTrip() throws {
        let manifest = sampleBuiltinManifest()
        let data = try encoder.encode(manifest)
        let decoded = try decoder.decode(Manifest.self, from: data)
        let reEncoded = try encoder.encode(decoded)

        XCTAssertEqual(manifest.id, decoded.id)
        XCTAssertEqual(manifest.kind, decoded.kind)
        XCTAssertEqual(manifest.displayName, decoded.displayName)
        XCTAssertEqual(manifest.description, decoded.description)
        XCTAssertEqual(manifest.utteranceExamples, decoded.utteranceExamples)
        XCTAssertEqual(manifest.parameters, decoded.parameters)
        XCTAssertEqual(manifest.riskTier, decoded.riskTier)
        XCTAssertEqual(manifest.enabled, decoded.enabled)
        XCTAssertEqual(manifest.scriptRef, decoded.scriptRef)
        XCTAssertEqual(manifest.timeoutSeconds, decoded.timeoutSeconds)
        XCTAssertEqual(manifest.generatedBy, decoded.generatedBy)
        XCTAssertEqual(data, reEncoded)
    }

    // MARK: - User automation manifest round-trip

    func testUserAutomationManifestRoundTrip() throws {
        let manifest = sampleUserAutomationManifest()
        let data = try encoder.encode(manifest)
        let decoded = try decoder.decode(Manifest.self, from: data)

        XCTAssertEqual(manifest.id, decoded.id)
        XCTAssertEqual(manifest.kind, decoded.kind)
        XCTAssertEqual(manifest.scriptRef, decoded.scriptRef)
        XCTAssertEqual(manifest.scriptSha256, decoded.scriptSha256)
        XCTAssertEqual(manifest.schedule?.type, decoded.schedule?.type)
        XCTAssertEqual(manifest.schedule?.calendar?.hour, decoded.schedule?.calendar?.hour)
        XCTAssertEqual(manifest.schedule?.calendar?.minute, decoded.schedule?.calendar?.minute)
        XCTAssertEqual(manifest.permissions.fileWritePaths, decoded.permissions.fileWritePaths)
        XCTAssertEqual(manifest.createdAt, decoded.createdAt)
        XCTAssertEqual(manifest.updatedAt, decoded.updatedAt)
        XCTAssertEqual(manifest.generatedBy, decoded.generatedBy)
    }

    // MARK: - Failure state defaults

    func testFailureStateDefaults() throws {
        let json = """
            {
              "schema_version": 1,
              "id": "test_skill",
              "kind": "builtin",
              "description": "A test skill for validating default values.",
              "parameters": { "type": "object", "properties": {} },
              "permissions": { "network": false },
              "risk_tier": "low",
              "enabled": true,
              "generated_by": "builtin"
            }
            """
        let data = Data(json.utf8)
        let decoded = try decoder.decode(Manifest.self, from: data)

        XCTAssertEqual(decoded.failureState.consecutiveFailures, 0)
        XCTAssertEqual(decoded.failureState.maxConsecutiveFailures, 3)
        XCTAssertNil(decoded.failureState.lastFailureAt)
        XCTAssertNil(decoded.failureState.lastSuccessAt)
        XCTAssertEqual(decoded.failureState.autoDisabled, false)
    }

    func testFailureStateWithExplicitValues() throws {
        let json = """
            {
              "schema_version": 1,
              "id": "test_skill",
              "kind": "builtin",
              "description": "A test skill with explicit failure state.",
              "parameters": { "type": "object", "properties": {} },
              "permissions": { "network": false },
              "risk_tier": "low",
              "enabled": true,
              "generated_by": "builtin",
              "failure_state": {
                "consecutive_failures": 2,
                "max_consecutive_failures": 5,
                "last_failure_at": "2024-01-15T10:30:00Z",
                "last_success_at": "2024-01-14T08:00:00Z",
                "auto_disabled": false
              }
            }
            """
        let data = Data(json.utf8)
        let decoded = try decoder.decode(Manifest.self, from: data)

        XCTAssertEqual(decoded.failureState.consecutiveFailures, 2)
        XCTAssertEqual(decoded.failureState.maxConsecutiveFailures, 5)
        XCTAssertNotNil(decoded.failureState.lastFailureAt)
        XCTAssertNotNil(decoded.failureState.lastSuccessAt)
        XCTAssertEqual(decoded.failureState.autoDisabled, false)
    }

    // MARK: - Default values

    func testDefaultTimeoutSeconds() throws {
        let json = """
            {
              "schema_version": 1,
              "id": "test_default",
              "kind": "builtin",
              "description": "A test skill checking timeout default.",
              "parameters": { "type": "object", "properties": {} },
              "permissions": { "network": false },
              "risk_tier": "low",
              "enabled": true,
              "generated_by": "builtin"
            }
            """
        let decoded = try decoder.decode(Manifest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.timeoutSeconds, 60)
    }

    func testDefaultUtteranceExamples() throws {
        let json = """
            {
              "schema_version": 1,
              "id": "test_default",
              "kind": "builtin",
              "description": "A test skill checking utterance examples default.",
              "parameters": { "type": "object", "properties": {} },
              "permissions": { "network": false },
              "risk_tier": "low",
              "enabled": true,
              "generated_by": "builtin"
            }
            """
        let decoded = try decoder.decode(Manifest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.utteranceExamples, [])
    }

    // MARK: - ManifestKind coding

    func testManifestKindBuiltinRawValue() {
        XCTAssertEqual(ManifestKind.builtin.rawValue, "builtin")
    }

    func testManifestKindUserAutomationRawValue() {
        XCTAssertEqual(ManifestKind.userAutomation.rawValue, "user_automation")
    }

    // MARK: - GeneratedBy coding

    func testGeneratedByRawValues() {
        XCTAssertEqual(GeneratedBy.builtin.rawValue, "builtin")
        XCTAssertEqual(GeneratedBy.localLlm.rawValue, "local_llm")
        XCTAssertEqual(GeneratedBy.cloudLlm.rawValue, "cloud_llm")
        XCTAssertEqual(GeneratedBy.manual.rawValue, "manual")
    }

    // MARK: - ScheduleType coding

    func testScheduleTypeRawValues() {
        XCTAssertEqual(ScheduleType.interval.rawValue, "interval")
        XCTAssertEqual(ScheduleType.calendar.rawValue, "calendar")
    }

    // MARK: - Decode fixture JSON

    func testDecodeOpenApplicationFixture() throws {
        let data = try fixtureData(named: "open_application")
        let manifest = try decoder.decode(Manifest.self, from: data)
        XCTAssertEqual(manifest.id, "open_application")
        XCTAssertEqual(manifest.kind, .builtin)
        XCTAssertEqual(manifest.riskTier, .low)
        XCTAssertNil(manifest.scriptRef)
    }

    // MARK: - Helpers

    private func sampleUserAutomationManifest() -> Manifest {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Manifest(
            schemaVersion: 1,
            id: "backup_notes",
            kind: .userAutomation,
            displayName: "Backup Notes",
            description: "Back up the Notes database to a specified folder on a schedule.",
            utteranceExamples: ["backup my notes"],
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("destination")]),
                "properties": .object([
                    "destination": .object(["type": .string("string")])
                ]),
            ]),
            permissions: ManifestPermissions(
                network: false,
                networkHosts: [],
                fileWritePaths: ["~/Backups/Notes"],
                requires: []
            ),
            schedule: ManifestSchedule(
                type: .calendar,
                intervalSeconds: nil,
                calendar: CalendarSchedule(minute: 0, hour: 2),
                runAtLoad: false
            ),
            riskTier: .confirm,
            enabled: true,
            scriptRef: "scripts/backup_notes.sh",
            scriptSha256: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            timeoutSeconds: 300,
            failureState: FailureState(),
            createdAt: now,
            updatedAt: now,
            generatedBy: .manual
        )
    }

    private func sampleBuiltinManifest() -> Manifest {
        Manifest(
            schemaVersion: 1,
            id: "open_application",
            kind: .builtin,
            displayName: "Open Application",
            description: "Launch or switch focus to a macOS application the user names.",
            utteranceExamples: ["open Safari", "launch Xcode"],
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("app_name")]),
                "properties": .object([
                    "app_name": .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                    ])
                ]),
            ]),
            permissions: ManifestPermissions(),
            schedule: nil,
            riskTier: .low,
            enabled: true,
            scriptRef: nil,
            scriptSha256: nil,
            timeoutSeconds: 60,
            failureState: FailureState(),
            createdAt: nil,
            updatedAt: nil,
            generatedBy: .builtin
        )
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }
}
