import XCTest

@testable import Configuration

/// Schema v6 (P5a Phase 4): `tone`, `dictation`, and `text_insertion` blocks.
/// v5 files migrate by bumping the version stamp; tolerant decode supplies defaults.
final class SettingsMigrationV6Tests: XCTestCase {

    func testV5FileWithoutNewBlocksLoadsAsV6WithDefaults() throws {
        let v5 = Data(
            """
            {"schema_version":5,
            "hotkeys":{"command_mode":{"key_code":36,"modifiers":["command"],"mode":"push_to_talk"},
            "dictation_mode":{"key_code":49,"modifiers":["control"],"mode":"push_to_talk"}},
            "model_tier":"16gb"}
            """.utf8)

        let decoded = try SettingsCodec.decode(v5)

        XCTAssertEqual(decoded.migratedFrom, 5)
        XCTAssertEqual(decoded.settings.schemaVersion, 6)
        XCTAssertEqual(decoded.settings.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(decoded.settings.tone.defaultPreset, .asIs)
        XCTAssertTrue(decoded.settings.dictation.cleanupEnabled)
        XCTAssertEqual(decoded.settings.textInsertion.appOverrides, [:])
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.keyCode, 36)
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.modifiers, [.command])
        XCTAssertEqual(decoded.settings.modelTier, "16gb")
    }

    func testExistingProfessionalTonePresetIsPreserved() throws {
        let json = Data(
            """
            {"schema_version":5,
            "tone":{"default_preset":"professional","available":["as_is","professional","casual","concise"]}}
            """.utf8)

        let decoded = try SettingsCodec.decode(json)

        XCTAssertEqual(decoded.settings.tone.defaultPreset, .professional)
        XCTAssertEqual(decoded.settings.schemaVersion, Settings.currentSchemaVersion)
    }

    func testExplicitCleanupDisabledAndAppOverridesSurvive() throws {
        let json = Data(
            """
            {"schema_version":6,
            "dictation":{"cleanup_enabled":false},
            "text_insertion":{"app_overrides":{"com.microsoft.VSCode":"paste","com.apple.TextEdit":"ax"}}}
            """.utf8)

        let decoded = try SettingsCodec.decode(json)

        XCTAssertNil(decoded.migratedFrom)
        XCTAssertFalse(decoded.settings.dictation.cleanupEnabled)
        XCTAssertEqual(decoded.settings.textInsertion.appOverrides["com.microsoft.VSCode"], .paste)
        XCTAssertEqual(decoded.settings.textInsertion.appOverrides["com.apple.TextEdit"], .ax)
    }

    func testUnknownTonePresetFallsBackToAsIs() throws {
        let json = Data(#"{"schema_version":6,"tone":{"default_preset":"shouty"}}"#.utf8)

        let settings = try SettingsCodec.decode(json).settings

        XCTAssertEqual(settings.tone.defaultPreset, .asIs)
    }

    func testEncodeRoundTripsV6Blocks() throws {
        var settings = Settings.defaults
        settings.tone.defaultPreset = .casual
        settings.dictation.cleanupEnabled = false
        settings.textInsertion.appOverrides = ["com.google.Chrome": .paste]

        let data = try SettingsCodec.encode(settings)
        XCTAssertEqual(try SettingsCodec.decode(data).settings, settings)

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"schema_version\""))
        XCTAssertTrue(text.contains("\"default_preset\""))
        XCTAssertTrue(text.contains("\"cleanup_enabled\""))
        XCTAssertTrue(text.contains("\"app_overrides\""))
        XCTAssertTrue(text.contains("\"text_insertion\""))
    }

    func testDefaultsMatchTheSpec() {
        XCTAssertEqual(Settings.currentSchemaVersion, 6)
        XCTAssertEqual(Settings.defaults.tone.defaultPreset, .asIs)
        XCTAssertTrue(Settings.defaults.dictation.cleanupEnabled)
        XCTAssertEqual(Settings.defaults.textInsertion.appOverrides, [:])
        XCTAssertEqual(Array(Settings.TonePreset.allCases), [.asIs, .professional, .casual, .concise])
    }
}
