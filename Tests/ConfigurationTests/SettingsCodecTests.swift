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
        // A current-version (v3) document whose audio cue + hotkeys are non-default
        // must decode to those values and report no migration.
        let json = Data(
            """
            {"schema_version":3,
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
        let json = Data(#"{"schema_version":3,"indicators":{"audio_cue_on_listen":false}}"#.utf8)

        let settings = try SettingsCodec.decode(json).settings

        XCTAssertFalse(settings.indicators.audioCueOnListen)  // the specified value
        XCTAssertEqual(settings.indicators.showLocalCloudIndicator, Settings.Indicators().showLocalCloudIndicator)
        XCTAssertEqual(settings.indicators.audioCueOnProcessing, Settings.Indicators().audioCueOnProcessing)
        XCTAssertEqual(settings.indicators.overlayPosition, Settings.Indicators().overlayPosition)
        XCTAssertEqual(settings.hotkeys, Settings.Hotkeys(), "absent hotkeys block must default")
        XCTAssertEqual(settings.privacy, Settings.Privacy(), "absent privacy block must default")
        XCTAssertEqual(settings.onboarding, Settings.OnboardingProgress(), "absent onboarding block must default")
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
        // hotkeys block introduced in v2 and the privacy/onboarding blocks
        // introduced in v3 (the v0→v1→v2→v3 chain fills all of them).
        XCTAssertTrue(decoded.settings.indicators.showLocalCloudIndicator)
        XCTAssertFalse(decoded.settings.indicators.audioCueOnProcessing)
        XCTAssertEqual(decoded.settings.indicators.overlayPosition, .bottomCenter)
        XCTAssertEqual(decoded.settings.hotkeys, Settings.Hotkeys())
        XCTAssertEqual(decoded.settings.privacy, Settings.Privacy())
        XCTAssertEqual(decoded.settings.onboarding, Settings.OnboardingProgress())
    }

    // MARK: - v1 → v2 forward migration (Phase 5: the `hotkeys` block)

    func testV1FileMigratesToV2GainingDefaultHotkeysWithoutIndicatorLoss() throws {
        // A real v1 file: schema_version 1, a fully-specified `indicators` block with
        // NON-default values, and no `hotkeys` (v1 had no such block). Migrating
        // forward (v1 → v2 → v3) must (a) report the upgrade from v1, (b) add the
        // default hotkeys, and (c) preserve every existing indicators value untouched.
        let v1 = Data(
            """
            {"schema_version":1,"indicators":{"show_local_cloud_indicator":false,
            "audio_cue_on_listen":false,"audio_cue_on_processing":true,"overlay_position":"top_center"}}
            """.utf8)

        let decoded = try SettingsCodec.decode(v1)

        XCTAssertEqual(decoded.migratedFrom, 1)
        XCTAssertEqual(decoded.settings.schemaVersion, Settings.currentSchemaVersion)

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

    // MARK: - Encode: preserving unmodeled top-level blocks (§2.5 forward-compat)

    func testEncodeMergingPreservesUnmodeledTopLevelBlock() throws {
        // `tone` is a real §2.5 block this build doesn't model yet (a future block a
        // newer build writes is the same shape of problem — Phase 10 modeled
        // `privacy`, so `tone` is now the stand-in unmodeled example). A decode →
        // re-encode round trip must not destroy it.
        let existing = Data(
            """
            {"schema_version":2,"hotkeys":{},"indicators":{},
            "tone":{"default_preset":"as_is","available":["as_is","professional"]}}
            """.utf8)

        let data = try SettingsCodec.encode(.defaults, mergingUnknownTopLevelKeysFrom: existing)

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tone = try XCTUnwrap(object["tone"] as? [String: Any])
        XCTAssertEqual(tone["default_preset"] as? String, "as_is")
        XCTAssertEqual(tone["available"] as? [String], ["as_is", "professional"])

        // Modeled blocks reflect the passed-in `Settings`, not whatever was on disk.
        XCTAssertEqual(try SettingsCodec.decode(data).settings, .defaults)
    }

    func testEncodeMergingDropsLegacyKeyMigrationHasAlreadyConsumed() throws {
        // The mechanism merges against the *migrated* view of the existing document,
        // not the raw bytes — otherwise a pre-migration key a step already folded
        // elsewhere (v0's flat `audio_cue`, moved into `indicators.audio_cue_on_listen`)
        // would resurface as a stale duplicate every time the file is re-saved.
        let legacy = Data(#"{"audio_cue":false}"#.utf8)

        let data = try SettingsCodec.encode(.defaults, mergingUnknownTopLevelKeysFrom: legacy)

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["audio_cue"], "a key migration already folded elsewhere must not resurface")
    }

    func testEncodeMergingFallsBackToModeledEncodingWhenExistingIsNilOrUnparseable() throws {
        let withNil = try SettingsCodec.encode(.defaults, mergingUnknownTopLevelKeysFrom: nil)
        XCTAssertEqual(try SettingsCodec.decode(withNil).settings, .defaults)

        let withGarbage = try SettingsCodec.encode(.defaults, mergingUnknownTopLevelKeysFrom: Data("not json".utf8))
        XCTAssertEqual(try SettingsCodec.decode(withGarbage).settings, .defaults)
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

    // MARK: - Privacy + Onboarding blocks (Phase 10; User Stories 22, 24)

    func testDefaultsHaveUndisclosedPrivacyAndFreshOnboarding() {
        XCTAssertFalse(Settings.defaults.privacy.networkUtilitiesDisclosed)
        XCTAssertFalse(Settings.defaults.onboarding.completed)
        XCTAssertEqual(Settings.defaults.onboarding.resumeStep, "welcome")
    }

    func testCurrentVersionFileWithPrivacyAndOnboardingDecodesThoseValues() throws {
        let json = Data(
            """
            {"schema_version":3,
            "privacy":{"network_utilities_disclosed":true},
            "onboarding":{"completed":true,"resume_step":"hotkeys"}}
            """.utf8)

        let settings = try SettingsCodec.decode(json).settings

        XCTAssertTrue(settings.privacy.networkUtilitiesDisclosed)
        XCTAssertTrue(settings.onboarding.completed)
        XCTAssertEqual(settings.onboarding.resumeStep, "hotkeys")
    }

    func testV2FileMigratesToV3GainingDefaultPrivacyAndOnboardingWithoutLoss() throws {
        // A real v2 file (Phase 9's shape): schema_version 2, hotkeys + indicators
        // set, no privacy/onboarding block (v2 predates both). Migrating to v3 must
        // add safe defaults for both without disturbing the existing data.
        let v2 = Data(
            """
            {"schema_version":2,
            "hotkeys":{"command_mode":{"key_code":36,"modifiers":["command"],"mode":"push_to_talk"}},
            "indicators":{"audio_cue_on_listen":false}}
            """.utf8)

        let decoded = try SettingsCodec.decode(v2)

        XCTAssertEqual(decoded.migratedFrom, 2)
        XCTAssertEqual(decoded.settings.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertFalse(decoded.settings.privacy.networkUtilitiesDisclosed)
        XCTAssertFalse(decoded.settings.onboarding.completed)
        XCTAssertEqual(decoded.settings.onboarding.resumeStep, "welcome")
        // No loss of the existing v2 data.
        XCTAssertEqual(decoded.settings.hotkeys.commandMode.keyCode, 36)
        XCTAssertFalse(decoded.settings.indicators.audioCueOnListen)
    }

    func testV2MigrationPreservesAnExplicitPrivacyBlockIfSomehowPresent() throws {
        // Defensive, mirrors `testV1MigrationPreservesAnExplicitlyBoundHotkeyIfPresent`:
        // the step only fills a MISSING block — an already-present one must survive.
        let v2 = Data(#"{"schema_version":2,"privacy":{"network_utilities_disclosed":true}}"#.utf8)

        let decoded = try SettingsCodec.decode(v2)

        XCTAssertTrue(decoded.settings.privacy.networkUtilitiesDisclosed)
    }

    func testEncodeRoundTripsPrivacyAndOnboarding() throws {
        var settings = Settings.defaults
        settings.privacy.networkUtilitiesDisclosed = true
        settings.onboarding.completed = true
        settings.onboarding.resumeStep = "summary"

        let data = try SettingsCodec.encode(settings)
        XCTAssertEqual(try SettingsCodec.decode(data).settings, settings)
    }
}
