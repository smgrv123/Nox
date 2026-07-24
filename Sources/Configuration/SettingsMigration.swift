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

    /// Steps in ascending order, one per version bump. A later phase that adds a
    /// field (e.g. `hotkeys`, bumping to v2) appends a `from: 1, to: 2` step here —
    /// nothing else changes. Computed (not stored) so the closures never become
    /// shared global state.
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
            }
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
