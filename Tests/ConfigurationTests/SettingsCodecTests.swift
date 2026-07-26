import XCTest

@testable import Configuration

/// Pure settings (de)serialisation + forward migration (docs/05-lld.md §1.2 / §2.5).
///
/// Every case runs straight from in-memory `Data`/JSON — no disk — per specs/P1
/// §"Testing Decisions" (the migration path must be unit-testable without touching
/// the real Application Support tree). Disk behaviour (missing/corrupt/round-trip
/// through a file) is covered separately by `SettingsStoreTests`.
final class SettingsCodecTests: XCTestCase {

    // MARK: - Current-version decode

    func testCurrentVersionFileDecodesDirectlyWithoutMigration() throws {
        // A current-version (v2) document whose audio cue + hotkeys are non-default
        // must decode to those values and report no migration.
        let json = Data(
            """
            {"schema_version":2,
            "hotkeys":{"command_mode":{"key_code":36,"modifiers":["command","shift"],"mode":"push_to_talk"},
            "dictation_mode":{"key_code":49,"modifiers":["control"],"mode":"push_to_talk"}},
            "indicators":{"show_local_cloud_indicator":false,
            "audio_cue_on_listen":false,"audio_cue_on_processing":true,"overlay_position":"top_center"}}
            """.utf8)

        let decoded = try SettingsCodec.decode(json)

        XCTAssertNil(decoded.migratedFrom)
        XCTAssertEqual(decoded.settings.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.keyCode, 36)
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.modifiers, [.command, .shift])
        XCTAssertEqual(decoded.settings.hotkeys.dictationMode.modifiers, [.control])
        XCTAssertFalse(decoded.settings.indicators.showLocalCloudIndicator)
        XCTAssertFalse(decoded.settings.indicators.audioCueOnListen)
        XCTAssertTrue(decoded.settings.indicators.audioCueOnProcessing)
        XCTAssertEqual(decoded.settings.indicators.overlayPosition, .topCenter)
    }

    func testDecodeIsTolerantOfMissingFields() throws {
        // A current-version file that only specifies one field (e.g. written by an
        // older point-build) must load, with every unspecified field — including the
        // whole `hotkeys` block — falling back to its default, never a decode failure.
        let json = Data(#"{"schema_version":2,"indicators":{"audio_cue_on_listen":false}}"#.utf8)

        let settings = try SettingsCodec.decode(json).settings

        XCTAssertFalse(settings.indicators.audioCueOnListen)  // the specified value
        XCTAssertEqual(settings.indicators.showLocalCloudIndicator, Settings.Indicators().showLocalCloudIndicator)
        XCTAssertEqual(settings.indicators.audioCueOnProcessing, Settings.Indicators().audioCueOnProcessing)
        XCTAssertEqual(settings.indicators.overlayPosition, Settings.Indicators().overlayPosition)
        XCTAssertEqual(settings.hotkeys, Settings.Hotkeys(), "absent hotkeys block must default")
    }

    // MARK: - Forward migration (the acceptance-critical case)

    func testLegacyV0FileMigratesForwardWithoutDataLoss() throws {
        // v0 = pre-envelope layout: NO schema_version, a flat `audio_cue` flag.
        // Migration must (a) detect v0, (b) carry the user's flag over to
        // indicators.audio_cue_on_listen intact — the proof of no data loss is that
        // the migrated value is `false`, NOT the v1 default of `true` — and
        // (c) default every new v1 field sanely.
        let legacy = Data(#"{"audio_cue":false}"#.utf8)

        let decoded = try SettingsCodec.decode(legacy)

        XCTAssertEqual(decoded.migratedFrom, 0)
        XCTAssertEqual(decoded.settings.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertFalse(decoded.settings.indicators.audioCueOnListen, "user's v0 value was lost")
        // New fields the user never had get defaults, not garbage — including the
        // hotkeys block introduced in v2 (the v0→v1→v2 chain fills it).
        XCTAssertTrue(decoded.settings.indicators.showLocalCloudIndicator)
        XCTAssertFalse(decoded.settings.indicators.audioCueOnProcessing)
        XCTAssertEqual(decoded.settings.indicators.overlayPosition, .bottomCenter)
        XCTAssertEqual(decoded.settings.hotkeys, Settings.Hotkeys())
    }

    // MARK: - v1 → v2 forward migration (Phase 5: the `hotkeys` block)

    func testV1FileMigratesToV2GainingDefaultHotkeysWithoutIndicatorLoss() throws {
        // A real v1 file: schema_version 1, a fully-specified `indicators` block with
        // NON-default values, and no `hotkeys` (v1 had no such block). Migrating to v2
        // must (a) report the upgrade from v1, (b) add the default hotkeys, and
        // (c) preserve every existing indicators value untouched.
        let v1 = Data(
            """
            {"schema_version":1,"indicators":{"show_local_cloud_indicator":false,
            "audio_cue_on_listen":false,"audio_cue_on_processing":true,"overlay_position":"top_center"}}
            """.utf8)

        let decoded = try SettingsCodec.decode(v1)

        XCTAssertEqual(decoded.migratedFrom, 1)
        XCTAssertEqual(decoded.settings.schemaVersion, 2)

        // (b) default hotkeys appear (⌥Space command, ⌃Space dictation, push-to-talk).
        XCTAssertEqual(decoded.settings.hotkeys, Settings.Hotkeys())
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.keyCode, 49)
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.modifiers, [.option])
        XCTAssertEqual(decoded.settings.hotkeys.dictationMode.keyCode, 49)
        XCTAssertEqual(decoded.settings.hotkeys.dictationMode.modifiers, [.control])
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.mode, .pushToTalk)

        // (c) no loss: every v1 indicators value survives the migration exactly.
        XCTAssertFalse(decoded.settings.indicators.showLocalCloudIndicator)
        XCTAssertFalse(decoded.settings.indicators.audioCueOnListen)
        XCTAssertTrue(decoded.settings.indicators.audioCueOnProcessing)
        XCTAssertEqual(decoded.settings.indicators.overlayPosition, .topCenter)
    }

    func testV1MigrationPreservesAnExplicitlyBoundHotkeyIfPresent() throws {
        // Defensive: if a v1 file somehow already carries a `hotkeys` block, migration
        // must NOT clobber it with the defaults (the step only fills a missing block).
        let v1 = Data(
            """
            {"schema_version":1,
            "hotkeys":{"command_mode":{"key_code":100,"modifiers":["command"],"mode":"push_to_talk"}}}
            """.utf8)

        let decoded = try SettingsCodec.decode(v1)

        XCTAssertEqual(decoded.migratedFrom, 1)
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.keyCode, 100)
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.modifiers, [.command])
        // The unspecified dictation binding still tolerant-decodes to its default.
        XCTAssertEqual(
            decoded.settings.hotkeys.dictationMode, Settings.HotkeyBinding(keyCode: 49, modifiers: [.control]))
    }

    func testExplicitV0VersionAlsoMigrates() throws {
        // The same legacy layout, but with an explicit `schema_version: 0`.
        let legacy = Data(#"{"schema_version":0,"audio_cue":true}"#.utf8)

        let decoded = try SettingsCodec.decode(legacy)

        XCTAssertEqual(decoded.migratedFrom, 0)
        XCTAssertTrue(decoded.settings.indicators.audioCueOnListen)
    }

    func testMigratorStampsCurrentSchemaVersion() {
        // A v0 object with no version key is normalised to the current version.
        let migrated = SettingsMigrator.migrate(["audio_cue": false], from: 0)
        XCTAssertEqual(migrated["schema_version"] as? Int, Settings.currentSchemaVersion)
        // The rename landed and the legacy key is gone.
        let indicators = migrated["indicators"] as? [String: Any]
        XCTAssertEqual(indicators?["audio_cue_on_listen"] as? Bool, false)
        XCTAssertNil(migrated["audio_cue"])
    }

    // MARK: - Unrecoverable inputs

    func testUnparseableDataThrowsUnreadable() {
        XCTAssertThrowsError(try SettingsCodec.decode(Data("not json at all".utf8))) { error in
            XCTAssertEqual(error as? SettingsDecodeError, .unreadable)
        }
    }

    func testNonObjectTopLevelThrowsUnreadable() {
        // Valid JSON, but the document root must be an object.
        XCTAssertThrowsError(try SettingsCodec.decode(Data("[1,2,3]".utf8))) { error in
            XCTAssertEqual(error as? SettingsDecodeError, .unreadable)
        }
    }

    func testNewerVersionThrowsUnsupported() {
        // A file from a future build must not be silently down-migrated.
        let future = Data(#"{"schema_version":999,"indicators":{}}"#.utf8)
        XCTAssertThrowsError(try SettingsCodec.decode(future)) { error in
            XCTAssertEqual(error as? SettingsDecodeError, .unsupportedVersion(999))
        }
    }

    // MARK: - Encode

    func testEncodeRoundTripsDefaults() throws {
        let data = try SettingsCodec.encode(.defaults)
        XCTAssertEqual(try SettingsCodec.decode(data).settings, .defaults)
    }

    func testEncodeRoundTripsChangedValues() throws {
        var settings = Settings.defaults
        settings.indicators.audioCueOnListen = false
        settings.indicators.overlayPosition = .topCenter

        let data = try SettingsCodec.encode(settings)
        XCTAssertEqual(try SettingsCodec.decode(data).settings, settings)
    }

    func testEncodedFileIsHumanReadableSnakeCaseJSON() throws {
        // Users Stories 33/35: on-disk files are human-readable; §2.5 field names.
        let text = try XCTUnwrap(String(data: try SettingsCodec.encode(.defaults), encoding: .utf8))
        XCTAssertTrue(text.contains("\"schema_version\""))
        XCTAssertTrue(text.contains("\"audio_cue_on_listen\""))
        XCTAssertTrue(text.contains("\"command_mode\""))
        XCTAssertTrue(text.contains("\"key_code\""))
        XCTAssertTrue(text.contains("\n"), "expected pretty-printed (multi-line) JSON")
    }

    // MARK: - Defaults match the spec (§2.5)

    func testDefaultHotkeysMatchTheSpec() {
        // §2.5: command_mode = ⌥Space, dictation_mode = ⌃Space, both push-to-talk.
        let hotkeys = Settings.defaults.hotkeys
        XCTAssertEqual(
            hotkeys.commandMode, Settings.HotkeyBinding(keyCode: 49, modifiers: [.option], mode: .pushToTalk))
        XCTAssertEqual(
            hotkeys.dictationMode, Settings.HotkeyBinding(keyCode: 49, modifiers: [.control], mode: .pushToTalk))
    }
}
