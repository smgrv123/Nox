import XCTest

@testable import Configuration

/// Schema v6 (P5a Phase 4): `tone` and `dictation` blocks. v6 originally also added
/// `text_insertion` (per-app AX/paste overrides), but AX insertion was removed
/// (dictation always pastes now) and with it the whole override struct — see
/// `testExistingTextInsertionBlockIsIgnoredNotRejected` below. The schema version was
/// deliberately **not** bumped for that removal, so decoding an existing v6 file that
/// still has `text_insertion` tolerates it as an unrecognized key — this suite
/// documents that it does not break decoding. The block does not stay on disk,
/// though: `encode(to:)` no longer knows about it, so the next settings save drops
/// it — harmless, since nothing reads it. v5 files migrate by bumping the version
/// stamp; tolerant decode supplies defaults.
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

    func testExplicitCleanupDisabledSurvives() throws {
        let json = Data(
            """
            {"schema_version":6,
            "dictation":{"cleanup_enabled":false}}
            """.utf8)

        let decoded = try SettingsCodec.decode(json)

        XCTAssertNil(decoded.migratedFrom)
        XCTAssertFalse(decoded.settings.dictation.cleanupEnabled)
    }

    /// A `settings.json` written by a build that still had `text_insertion` (or one a
    /// user hand-rolled) must keep decoding cleanly now that `Settings.TextInsertion`
    /// is gone — `Settings.CodingKeys` has no case for it, so `JSONDecoder` treats it
    /// as an unrecognized key and silently skips it rather than throwing. This proves
    /// decoding tolerates the leftover block; it does not survive on disk — the next
    /// save rewrites the file without it (see `testEncodeRoundTripsV6Blocks` below),
    /// which is fine since nothing reads it.
    func testExistingTextInsertionBlockIsIgnoredNotRejected() throws {
        let json = Data(
            """
            {"schema_version":6,
            "dictation":{"cleanup_enabled":false},
            "text_insertion":{"app_overrides":{"com.microsoft.VSCode":"paste","com.apple.TextEdit":"ax"}}}
            """.utf8)

        let decoded = try SettingsCodec.decode(json)

        XCTAssertNil(decoded.migratedFrom)
        XCTAssertFalse(decoded.settings.dictation.cleanupEnabled)
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

        let data = try SettingsCodec.encode(settings)
        XCTAssertEqual(try SettingsCodec.decode(data).settings, settings)

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"schema_version\""))
        XCTAssertTrue(text.contains("\"default_preset\""))
        XCTAssertTrue(text.contains("\"cleanup_enabled\""))
        XCTAssertFalse(text.contains("\"text_insertion\""), "the override machinery is gone — never re-written")
    }

    func testDefaultsMatchTheSpec() {
        XCTAssertEqual(Settings.currentSchemaVersion, 6)
        XCTAssertEqual(Settings.defaults.tone.defaultPreset, .asIs)
        XCTAssertTrue(Settings.defaults.dictation.cleanupEnabled)
        XCTAssertEqual(Array(Settings.TonePreset.allCases), [.asIs, .professional, .casual, .concise])
    }
}
