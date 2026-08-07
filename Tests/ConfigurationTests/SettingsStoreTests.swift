import XCTest

@testable import Configuration

/// The load/save façade + resilience policy (docs/05-lld.md §2.5 / §2.7).
///
/// Exercised against a throwaway temp directory — never the real
/// `~/Library/Application Support/Aide/` (specs/P1 §"Testing Decisions": the file URL
/// is injected). Covers the three acceptance criteria that need disk: round-trip
/// persistence, forward-migration on load, and missing/corrupt fallback.
final class SettingsStoreTests: XCTestCase {

    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appending(path: "aide-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: directory)
    }

    private var settingsURL: URL { directory.appending(path: "settings.json") }

    /// A store whose non-nominal outcomes are captured for assertion.
    private func makeStore(signals: SignalRecorder = SignalRecorder()) -> SettingsStore {
        SettingsStore(
            fileURL: settingsURL,
            now: { Date(timeIntervalSince1970: 1_753_347_040) },  // 2025-07-24T09:10:40Z
            signal: { signals.record($0) })
    }

    // MARK: - Acceptance #1: round-trip a changed value

    func testChangedValuePersistsAcrossReload() throws {
        var settings = Settings.defaults
        XCTAssertTrue(settings.indicators.audioCueOnListen, "precondition: default is on")
        settings.indicators.audioCueOnListen = false
        settings.indicators.overlayPosition = .topCenter

        try makeStore().save(settings)

        // A fresh store at the same URL (the relaunch analog) restores the value.
        let reloaded = makeStore().load()
        XCTAssertFalse(reloaded.indicators.audioCueOnListen)
        XCTAssertEqual(reloaded.indicators.overlayPosition, .topCenter)
        XCTAssertEqual(reloaded, settings)
    }

    func testSavedFileIsHumanReadableOnDisk() throws {
        try makeStore().save(.defaults)
        let text = try XCTUnwrap(String(data: try Data(contentsOf: settingsURL), encoding: .utf8))
        XCTAssertTrue(text.contains("\"schema_version\""))
        XCTAssertTrue(text.contains("\"audio_cue_on_listen\""))
    }

    // MARK: - Acceptance #2: forward migration on load

    func testOlderSchemaFileMigratesOnLoadAndSignals() throws {
        // Seed a v0 (pre-envelope) file with a non-default flag.
        try Data(#"{"audio_cue":false}"#.utf8).write(to: settingsURL)
        let signals = SignalRecorder()

        let loaded = makeStore(signals: signals).load()

        XCTAssertFalse(loaded.indicators.audioCueOnListen, "the v0 value was lost in migration")
        XCTAssertEqual(loaded.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(signals.all, [.migrated(from: 0)])
    }

    func testMigratedSettingsRewriteToCurrentSchemaOnSave() throws {
        try Data(#"{"audio_cue":false}"#.utf8).write(to: settingsURL)
        let store = makeStore()

        // Load (migrating) then save — the file on disk is now the current schema.
        try store.save(store.load())

        let text = try XCTUnwrap(String(data: try Data(contentsOf: settingsURL), encoding: .utf8))
        XCTAssertTrue(
            text.contains("\"schema_version\" : \(Settings.currentSchemaVersion)"),
            "rewritten file carries the current schema version")
        XCTAssertFalse(text.contains("\"audio_cue\""), "legacy flat key should be gone")
        XCTAssertTrue(text.contains("\"audio_cue_on_listen\" : false"), "migrated value must survive the rewrite")
    }

    // MARK: - Acceptance #3: missing / corrupt fall back to defaults, no crash

    func testMissingFileLoadsDefaultsAndSignalsMissing() {
        let signals = SignalRecorder()
        let loaded = makeStore(signals: signals).load()
        XCTAssertEqual(loaded, .defaults)
        XCTAssertEqual(signals.all, [.missing])
    }

    func testCorruptFileLoadsDefaultsBacksUpBytesAndSignals() throws {
        let garbage = Data("{ this is not valid json ".utf8)
        try garbage.write(to: settingsURL)
        let signals = SignalRecorder()

        let loaded = makeStore(signals: signals).load()

        XCTAssertEqual(loaded, .defaults, "a corrupt file must not crash — defaults instead")

        // Exactly one recovered signal, carrying a backup URL.
        guard case .recovered(let backupURL) = signals.all.first, signals.all.count == 1 else {
            return XCTFail("expected a single .recovered signal, got \(signals.all)")
        }
        let backup = try XCTUnwrap(backupURL)

        // The corrupt bytes are preserved for inspection, and moved aside so the next
        // save starts clean (the original path no longer holds the bad file).
        XCTAssertEqual(try Data(contentsOf: backup), garbage)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("settings.json.corrupt-"))
        XCTAssertFalse(fileManager.fileExists(atPath: settingsURL.path), "corrupt original should be moved aside")
    }

    func testCorruptRecoveryThenSaveReloadYieldsSavedValue() throws {
        try Data("garbage".utf8).write(to: settingsURL)
        let store = makeStore()

        _ = store.load()  // recovers to defaults, backs up
        var settings = Settings.defaults
        settings.indicators.audioCueOnListen = false
        try store.save(settings)

        XCTAssertEqual(makeStore().load(), settings)
    }

    // MARK: - Acceptance #4: unmodeled top-level blocks survive save() (§2.5)

    func testSaveDoesNotDropUnmodeledTopLevelBlocks() throws {
        // Seed a document with every currently-modeled block PLUS a real §2.5 block
        // (`tone`) this build's `Settings` doesn't represent yet (Phase 10 modeled
        // `privacy`, so `tone` is now the stand-in unmodeled example). A load →
        // modify a modeled field → save() cycle must keep `tone` byte-for-byte,
        // while the modeled change still lands.
        let seeded = Data(
            """
            {"schema_version":3,
            "hotkeys":{"command_mode":{"key_code":49,"modifiers":["option"],"mode":"push_to_talk"},
            "dictation_mode":{"key_code":49,"modifiers":["control"],"mode":"push_to_talk"}},
            "indicators":{"show_local_cloud_indicator":true,
            "audio_cue_on_listen":true,"audio_cue_on_processing":false,"overlay_position":"bottom_center"},
            "tone":{"default_preset":"as_is","available":["as_is","professional","casual","concise"]}}
            """.utf8)
        try seeded.write(to: settingsURL)
        let store = makeStore()

        var settings = store.load()
        settings.indicators.audioCueOnListen = false  // the modeled change
        try store.save(settings)

        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: settingsURL)) as? [String: Any])
        let tone = try XCTUnwrap(raw["tone"] as? [String: Any])
        XCTAssertEqual(tone["default_preset"] as? String, "as_is", "unmodeled block must survive save() verbatim")
        XCTAssertEqual(tone["available"] as? [String], ["as_is", "professional", "casual", "concise"])

        // Nothing modeled was lost either — the change persisted.
        let reloaded = makeStore().load()
        XCTAssertFalse(reloaded.indicators.audioCueOnListen)
        XCTAssertEqual(reloaded, settings)
    }

    // MARK: - Acceptance #5: onboarding + privacy round-trip (Phase 10)

    func testOnboardingProgressAndPrivacyDisclosurePersistAcrossReload() throws {
        var settings = Settings.defaults
        settings.onboarding.resumeStep = "permission_accessibility"
        settings.privacy.networkUtilitiesDisclosed = true

        try makeStore().save(settings)

        let reloaded = makeStore().load()
        XCTAssertEqual(reloaded.onboarding.resumeStep, "permission_accessibility")
        XCTAssertTrue(reloaded.privacy.networkUtilitiesDisclosed)
    }

    func testOldFileWithoutOnboardingOrPrivacyLoadsSafeDefaults() throws {
        // A pre-Phase-10 v2 file — no `privacy`/`onboarding` blocks at all. Loading
        // it must not crash and must yield the safe "not yet onboarded, not
        // disclosed" defaults (User Story 24's resumability depends on this never
        // blowing up on an older file).
        try Data(#"{"schema_version":2,"hotkeys":{},"indicators":{}}"#.utf8).write(to: settingsURL)

        let loaded = makeStore().load()

        XCTAssertFalse(loaded.onboarding.completed)
        XCTAssertEqual(loaded.onboarding.resumeStep, "welcome")
        XCTAssertFalse(loaded.privacy.networkUtilitiesDisclosed)
    }

    func testFirstRunSaveWithNoExistingFileWritesValidDocument() throws {
        // No prior file — first run / post-wipe. save() must not choke looking for
        // bytes to merge, and must still produce a decodable, current-schema document.
        XCTAssertFalse(fileManager.fileExists(atPath: settingsURL.path), "precondition: nothing on disk yet")

        try makeStore().save(.defaults)

        XCTAssertEqual(makeStore().load(), .defaults)
    }

    func testSaveWithCorruptExistingFileDoesNotThrowAndWritesModeledBlocks() throws {
        // A corrupt file sitting at the destination (e.g. save() called directly,
        // without going through load()'s backup-and-recover path first) must not
        // crash or throw the save — it should just fall back to the modeled encoding.
        try Data("{ not valid json".utf8).write(to: settingsURL)
        var settings = Settings.defaults
        settings.indicators.overlayPosition = .topCenter

        XCTAssertNoThrow(try makeStore().save(settings))

        XCTAssertEqual(makeStore().load(), settings)
    }
}

/// Thread-safe recorder for the store's non-nominal `Signal`s.
private final class SignalRecorder {
    private let lock = NSLock()
    private var signals: [SettingsStore.Signal] = []

    func record(_ signal: SettingsStore.Signal) {
        lock.lock()
        defer { lock.unlock() }
        signals.append(signal)
    }

    var all: [SettingsStore.Signal] {
        lock.lock()
        defer { lock.unlock() }
        return signals
    }
}
