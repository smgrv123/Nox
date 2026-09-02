import AideCore
import Foundation
import XCTest

@testable import SkillManifest

final class ManifestValidationTests: XCTestCase {

    // MARK: - Valid manifests

    func testValidBuiltinManifestHasNoIssues() {
        let manifest = makeBuiltin()
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.isEmpty, "Expected no issues, got: \(issues)")
    }

    func testValidUserAutomationManifestHasNoIssues() {
        let manifest = makeUserAutomation()
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.isEmpty, "Expected no issues, got: \(issues)")
    }

    // MARK: - ID validation

    func testRejectsIDWithUppercase() {
        let manifest = makeBuiltin(id: "OpenApp")
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.invalidID))
    }

    func testRejectsIDStartingWithNumber() {
        let manifest = makeBuiltin(id: "1app")
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.invalidID))
    }

    func testRejectsIDTooShort() {
        let manifest = makeBuiltin(id: "ab")
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.invalidID))
    }

    func testRejectsIDTooLong() {
        let longID = "a" + String(repeating: "b", count: 63)
        XCTAssertEqual(longID.count, 64)
        let manifest = makeBuiltin(id: longID)
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.isEmpty, "64-char id should be valid")

        let tooLongID = "a" + String(repeating: "b", count: 64)
        XCTAssertEqual(tooLongID.count, 65)
        let manifest2 = makeBuiltin(id: tooLongID)
        let issues2 = ManifestValidation.validate(manifest2)
        XCTAssertTrue(issues2.contains(.invalidID))
    }

    func testRejectsIDWithHyphens() {
        let manifest = makeBuiltin(id: "open-app")
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.invalidID))
    }

    func testRejectsIDWithSpaces() {
        let manifest = makeBuiltin(id: "open app")
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.invalidID))
    }

    func testAcceptsMinimumLengthID() {
        let manifest = makeBuiltin(id: "abc")
        let issues = ManifestValidation.validate(manifest)
        XCTAssertFalse(issues.contains(.invalidID))
    }

    // MARK: - Description validation

    func testRejectsDescriptionTooShort() {
        let manifest = makeBuiltin(description: "Hi")
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.descriptionOutOfRange))
    }

    func testRejectsDescriptionTooLong() {
        let manifest = makeBuiltin(description: String(repeating: "a", count: 401))
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.descriptionOutOfRange))
    }

    func testAcceptsDescriptionAtBoundaries() {
        let short = makeBuiltin(description: "abc")
        XCTAssertFalse(ManifestValidation.validate(short).contains(.descriptionOutOfRange))

        let long = makeBuiltin(description: String(repeating: "a", count: 400))
        XCTAssertFalse(ManifestValidation.validate(long).contains(.descriptionOutOfRange))
    }

    // MARK: - Utterance examples validation

    func testRejectsTooManyUtteranceExamples() {
        let manifest = makeBuiltin(
            utteranceExamples: (1...9).map { "example \($0)" }
        )
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.tooManyUtteranceExamples))
    }

    func testAcceptsEightUtteranceExamples() {
        let manifest = makeBuiltin(
            utteranceExamples: (1...8).map { "example \($0)" }
        )
        let issues = ManifestValidation.validate(manifest)
        XCTAssertFalse(issues.contains(.tooManyUtteranceExamples))
    }

    // MARK: - Parameters validation

    func testRejectsParametersWithoutTypeObject() {
        let manifest = makeBuiltin(
            parameters: .object(["type": .string("array")])
        )
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.parametersMustBeObject))
    }

    func testRejectsNonObjectParameters() {
        let manifest = makeBuiltin(parameters: .string("not an object"))
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.parametersMustBeObject))
    }

    // MARK: - User automation constraints

    func testRejectsUserAutomationMissingScriptRef() {
        let manifest = makeUserAutomation(scriptRef: nil)
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.userAutomationMissingScriptRef))
    }

    func testRejectsUserAutomationMissingScriptSha256() {
        let manifest = makeUserAutomation(scriptSha256: nil)
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.userAutomationMissingScriptSha256))
    }

    // MARK: - Builtin constraints

    func testRejectsBuiltinWithScriptRef() {
        let manifest = makeBuiltin(scriptRef: "scripts/something.sh")
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.builtinMustNotHaveScriptRef))
    }

    // MARK: - Timeout validation

    func testRejectsTimeoutBelowMinimum() {
        let manifest = makeBuiltin(timeoutSeconds: 0)
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.timeoutOutOfRange))
    }

    func testRejectsTimeoutAboveMaximum() {
        let manifest = makeBuiltin(timeoutSeconds: 3601)
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.timeoutOutOfRange))
    }

    func testAcceptsTimeoutAtBoundaries() {
        XCTAssertFalse(ManifestValidation.validate(makeBuiltin(timeoutSeconds: 1)).contains(.timeoutOutOfRange))
        XCTAssertFalse(ManifestValidation.validate(makeBuiltin(timeoutSeconds: 3600)).contains(.timeoutOutOfRange))
    }

    // MARK: - Schema version validation

    func testRejectsSchemaVersionNotOne() {
        let manifest = makeBuiltin(schemaVersion: 2)
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.unsupportedSchemaVersion))
    }

    func testRejectsSchemaVersionZero() {
        let manifest = makeBuiltin(schemaVersion: 0)
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.unsupportedSchemaVersion))
    }

    // MARK: - Multiple issues

    func testReturnsMultipleIssues() {
        let manifest = makeBuiltin(
            id: "X",
            description: "ab",
            timeoutSeconds: 0
        )
        let issues = ManifestValidation.validate(manifest)
        XCTAssertTrue(issues.contains(.invalidID))
        XCTAssertTrue(issues.contains(.descriptionOutOfRange))
        XCTAssertTrue(issues.contains(.timeoutOutOfRange))
    }

    // MARK: - Fixture manifests all pass

    func testAllFixtureManifestsPassValidation() throws {
        let decoder: JSONDecoder = {
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            dec.dateDecodingStrategy = .iso8601
            return dec
        }()

        let fixtureNames = [
            "open_application",
            "quit_application",
            "set_timer",
            "media_control",
            "take_screenshot",
            "current_time",
            "calculate",
            "general_qa",
            "screen_qa",
            "unit_conversion",
        ]

        for name in fixtureNames {
            let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
            let data = try Data(contentsOf: url)
            let manifest = try decoder.decode(Manifest.self, from: data)
            let issues = ManifestValidation.validate(manifest)
            XCTAssertTrue(issues.isEmpty, "Fixture '\(name)' should pass validation, got: \(issues)")
        }
    }

    // MARK: - Helpers

    private func makeBuiltin(
        schemaVersion: Int = 1,
        id: String = "test_skill",
        description: String = "A test skill for unit testing purposes.",
        utteranceExamples: [String] = [],
        parameters: JSONValue = .object(["type": .string("object"), "properties": .object([:])]),
        timeoutSeconds: Int = 60,
        scriptRef: String? = nil
    ) -> Manifest {
        Manifest(
            schemaVersion: schemaVersion,
            id: id,
            kind: .builtin,
            displayName: "Test Skill",
            description: description,
            utteranceExamples: utteranceExamples,
            parameters: parameters,
            permissions: ManifestPermissions(),
            schedule: nil,
            riskTier: .low,
            enabled: true,
            scriptRef: scriptRef,
            scriptSha256: nil,
            timeoutSeconds: timeoutSeconds,
            failureState: FailureState(),
            createdAt: nil,
            updatedAt: nil,
            generatedBy: .builtin
        )
    }

    private func makeUserAutomation(
        scriptRef: String? = "scripts/backup.sh",
        scriptSha256: String? = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    ) -> Manifest {
        Manifest(
            schemaVersion: 1,
            id: "user_backup",
            kind: .userAutomation,
            displayName: "User Backup",
            description: "Back up files to a specified folder on a schedule.",
            utteranceExamples: [],
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            permissions: ManifestPermissions(fileWritePaths: ["~/Backups"]),
            schedule: ManifestSchedule(type: .interval, intervalSeconds: 3600, runAtLoad: false),
            riskTier: .confirm,
            enabled: true,
            scriptRef: scriptRef,
            scriptSha256: scriptSha256,
            timeoutSeconds: 120,
            failureState: FailureState(),
            createdAt: nil,
            updatedAt: nil,
            generatedBy: .manual
        )
    }
}
