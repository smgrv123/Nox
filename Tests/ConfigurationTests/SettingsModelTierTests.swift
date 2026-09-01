import XCTest

@testable import Configuration

/// Model-tier codec + migration tests (Phase 5 · P2a; User Story 18).
///
/// Covers the `sttModelTier → modelTier` rename introduced by the v4→v5 migration
/// step and the round-trip encoding of the field. Split from `SettingsCodecTests` to
/// stay within the type-body-length lint budget.
final class SettingsModelTierTests: XCTestCase {

    // MARK: - sttModelTier → modelTier (Phase 5 · P2a; User Story 18): the confirmed onboarding Tier

    func testDefaultModelTierIsNilUntilOnboardingConfirmsOne() {
        // nil = "not yet confirmed" — the App layer falls back to detected RAM alone.
        XCTAssertNil(Settings.defaults.modelTier)
    }

    func testCurrentVersionFileWithModelTierDecodesIt() throws {
        let json = Data(#"{"schema_version":5,"model_tier":"8gb"}"#.utf8)
        let settings = try SettingsCodec.decode(json).settings
        XCTAssertEqual(settings.modelTier, "8gb")
    }

    func testV3FileMigratesToV5WithoutLossAndNoModelTier() throws {
        // A real v3 file (Phase 10's shape): no `model_tier` (v3 predates it). Migrating
        // through v4→v5 must leave it nil (not yet confirmed) without disturbing existing data.
        let v3 = Data(
            """
            {"schema_version":3,
            "hotkeys":{"command_mode":{"key_code":36,"modifiers":["command"],"mode":"push_to_talk"}},
            "privacy":{"network_utilities_disclosed":true},
            "onboarding":{"completed":true,"resume_step":"summary"}}
            """.utf8)

        let decoded = try SettingsCodec.decode(v3)

        XCTAssertEqual(decoded.migratedFrom, 3)
        XCTAssertEqual(decoded.settings.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertNil(decoded.settings.modelTier)
        // No loss of existing v3 data.
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.keyCode, 36)
        XCTAssertTrue(decoded.settings.privacy.networkUtilitiesDisclosed)
        XCTAssertTrue(decoded.settings.onboarding.completed)
    }

    func testV4FileMigratesToV5RenamingSttModelTierToModelTier() throws {
        // A real v4 file carries `stt_model_tier`; the v4→v5 migration must rename it
        // to `model_tier` so the current decoder picks it up under the new key.
        let v4 = Data(
            """
            {"schema_version":4,
            "stt_model_tier":"16gb",
            "hotkeys":{"command_mode":{"key_code":36,"modifiers":["command"],"mode":"push_to_talk"}},
            "privacy":{"network_utilities_disclosed":true},
            "onboarding":{"completed":true,"resume_step":"summary"}}
            """.utf8)

        let decoded = try SettingsCodec.decode(v4)

        XCTAssertEqual(decoded.migratedFrom, 4)
        XCTAssertEqual(decoded.settings.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(decoded.settings.modelTier, "16gb")
        // No loss of existing v4 data.
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.keyCode, 36)
        XCTAssertTrue(decoded.settings.privacy.networkUtilitiesDisclosed)
        XCTAssertTrue(decoded.settings.onboarding.completed)
    }

    func testV4FileWithNoSttModelTierMigratesCleanly() throws {
        // A v4 file that never had the tier confirmed (nil) must migrate without error.
        let v4 = Data(#"{"schema_version":4,"hotkeys":{}}"#.utf8)

        let decoded = try SettingsCodec.decode(v4)

        XCTAssertEqual(decoded.migratedFrom, 4)
        XCTAssertNil(decoded.settings.modelTier)
    }

    func testEncodeRoundTripsModelTier() throws {
        var settings = Settings.defaults
        settings.modelTier = "16gb"

        let data = try SettingsCodec.encode(settings)
        XCTAssertEqual(try SettingsCodec.decode(data).settings, settings)
    }
}
