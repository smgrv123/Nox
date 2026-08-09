import Foundation

/// Forward-migration of a raw `settings.json` document up to the current schema
/// version (docs/05-lld.md §1.2: "All persisted JSON documents carry an integer
/// `schema_version` … for forward-migration"; §2.5).
///
/// Migrations operate on the **raw JSON object** (`[String: Any]`) rather than a
/// decoded model, so the current `Settings` type never has to know the shape of any
/// older version. Each step renames / moves / defaults keys and bumps the version;
/// `SettingsCodec` runs the chain first, then decodes the normalised object once. New
/// fields a step doesn't set are supplied by `Settings`' tolerant decoder, so a step
/// only has to touch what actually *changed* between two versions.
struct SettingsMigration {

    /// The version this step upgrades **from**.
    let from: Int
    /// The version this step produces (`from + 1` in a stepwise chain).
    let to: Int
    /// Transform the raw object from `from`'s shape into `to`'s shape.
    let apply: (_ json: [String: Any]) -> [String: Any]
}

/// The ordered migration chain and the walker that applies it.
enum SettingsMigrator {

    /// Steps in ascending order, one per version bump. A phase that adds a field
    /// appends the next `from: N, to: N+1` step here — nothing else changes. Computed
    /// (not stored) so the closures never become shared global state.
    static var chain: [SettingsMigration] {
        [
            // v0 → v1. "v0" is the pre-envelope development layout: no `schema_version`
            // key and a single flat `audio_cue` flag. v1 (LLD §2.5) nests that flag as
            // `indicators.audio_cue_on_listen`. The user's value is carried over intact
            // (no data loss); every other v1 field is filled by tolerant decoding.
            SettingsMigration(from: 0, to: 1) { legacy in
                var migrated = legacy
                var indicators = (migrated["indicators"] as? [String: Any]) ?? [:]
                if let legacyAudioCue = migrated["audio_cue"] as? Bool {
                    indicators["audio_cue_on_listen"] = legacyAudioCue
                }
                migrated["indicators"] = indicators
                migrated.removeValue(forKey: "audio_cue")
                migrated["schema_version"] = 1
                return migrated
            },
            // v1 → v2 (Phase 5). v2 (LLD §2.5) adds the `hotkeys` block. A pre-v2 file
            // has no hotkeys, so we write the spec defaults (⌥Space command, ⌃Space
            // dictation, both push-to-talk). The user's `indicators` block is left
            // untouched — this step only adds `hotkeys`, so no existing value is lost.
            // (Canonical defaults live in `Settings.Hotkeys()`; mirrored here as raw
            // JSON, matching the v0→v1 step's style.)
            SettingsMigration(from: 1, to: 2) { v1 in
                var migrated = v1
                if migrated["hotkeys"] == nil {
                    migrated["hotkeys"] = [
                        "command_mode": ["key_code": 49, "modifiers": ["option"], "mode": "push_to_talk"],
                        "dictation_mode": ["key_code": 49, "modifiers": ["control"], "mode": "push_to_talk"],
                    ]
                }
                migrated["schema_version"] = 2
                return migrated
            },
            // v2 → v3 (Phase 10). v3 (LLD §2.5, §8) adds the `privacy` block (the
            // one-time network-utilities disclosure ack) and `onboarding` (first-run
            // resumability). A pre-v3 file has neither, so we write the same safe
            // defaults `Settings.Privacy()` / `Settings.OnboardingProgress()` would —
            // not-yet-disclosed, not-yet-onboarded, resuming at "welcome". Existing
            // `hotkeys`/`indicators` are left untouched — this step only adds the two
            // new blocks, so nothing already on disk is lost.
            SettingsMigration(from: 2, to: 3) { v2 in
                var migrated = v2
                if migrated["privacy"] == nil {
                    migrated["privacy"] = ["network_utilities_disclosed": false]
                }
                if migrated["onboarding"] == nil {
                    migrated["onboarding"] = ["completed": false, "resume_step": "welcome"]
                }
                migrated["schema_version"] = 3
                return migrated
            },
            // v3 → v4 (P2a Phase 5). v4 adds the top-level `stt_model_tier` scalar (the
            // onboarding-confirmed Whisper Tier). A pre-v4 file has no such key; leaving it
            // absent is itself the correct default (`nil` = "not yet confirmed") — `Settings`'
            // tolerant decoder already reads a missing key as `nil` — so this step only bumps
            // the version stamp, mirroring how a genuinely no-op field addition still gets a
            // documented migration hop rather than silently riding along on v3's shape.
            SettingsMigration(from: 3, to: 4) { v3 in
                var migrated = v3
                migrated["schema_version"] = 4
                return migrated
            },
        ]
    }

    /// Apply every step from `version` up to `Settings.currentSchemaVersion`, walking
    /// the chain one hop at a time. A file already at the current version passes
    /// through untouched; the envelope is stamped to the current version either way so
    /// the decoded model's `schema_version` is authoritative.
    static func migrate(_ json: [String: Any], from version: Int) -> [String: Any] {
        let stepsByFrom = Dictionary(uniqueKeysWithValues: chain.map { ($0.from, $0) })
        var working = json
        var current = version
        while current < Settings.currentSchemaVersion, let step = stepsByFrom[current] {
            working = step.apply(working)
            current = step.to
        }
        working["schema_version"] = Settings.currentSchemaVersion
        return working
    }
}
