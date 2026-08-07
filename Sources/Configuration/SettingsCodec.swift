import Foundation

/// Why a raw `settings.json` document could not be turned into `Settings`. Every
/// case is recoverable — `SettingsStore` maps all of them to safe defaults (User
/// Story 38: surface a working state, never crash) — but they are kept distinct so
/// the failure can be logged precisely.
enum SettingsDecodeError: Error, Equatable {
    /// Not parseable JSON, or the top level isn't a JSON object.
    case unreadable
    /// Newer than this build understands; Phase 3 does not down-migrate (the file is
    /// preserved by the store rather than truncated).
    case unsupportedVersion(Int)
    /// Parses as JSON but does not fit the migrated `Settings` model.
    case malformed
}

/// Pure (de)serialisation of the settings document — **no disk, no I/O**. Given raw
/// `Data`, it reads the `schema_version` envelope, runs the forward-migration chain
/// (`SettingsMigrator`), and decodes the normalised object once into `Settings`.
/// `SettingsStore` layers the file read/write + fallback policy on top; this layer is
/// exercised straight from in-memory `Data`/JSON so migration is unit-testable
/// without touching the real Application Support tree (specs/P1 §"Testing Decisions").
enum SettingsCodec {

    /// A successfully decoded document, plus the version it was migrated **from**
    /// (`nil` when the file was already current) so the caller can log the upgrade.
    struct Decoded: Equatable {
        let settings: Settings
        let migratedFrom: Int?
    }

    /// Decode raw file bytes into `Settings`, migrating forward if needed.
    /// Throws `SettingsDecodeError` for anything unrecoverable.
    static func decode(_ data: Data) throws -> Decoded {
        guard
            let parsed = try? JSONSerialization.jsonObject(with: data),
            let object = parsed as? [String: Any]
        else {
            throw SettingsDecodeError.unreadable
        }

        // A parseable object with no `schema_version` is the pre-envelope v0 layout.
        let version = (object["schema_version"] as? Int) ?? 0
        guard version <= Settings.currentSchemaVersion else {
            throw SettingsDecodeError.unsupportedVersion(version)
        }

        let migrated = SettingsMigrator.migrate(object, from: version)
        guard
            let migratedData = try? JSONSerialization.data(withJSONObject: migrated),
            let settings = try? decoder.decode(Settings.self, from: migratedData)
        else {
            throw SettingsDecodeError.malformed
        }

        return Decoded(
            settings: settings,
            migratedFrom: version < Settings.currentSchemaVersion ? version : nil)
    }

    /// Encode `Settings` to the bytes written to disk: pretty-printed with sorted keys
    /// so the file stays human-readable and diff-stable (User Stories 33/35).
    ///
    /// `existingData` is the raw bytes already on disk, if any (docs/05-lld.md §2.5:
    /// `settings.json` is a single document holding ALL config blocks — this build
    /// only *models* a subset of them). When present and parseable, any top-level key
    /// the current `Settings` model doesn't represent — a block a later phase of this
    /// build hasn't shipped yet, or one only a newer build understands — is copied
    /// over verbatim, so a decode → re-encode round trip never destroys it. Every
    /// modeled key (`schema_version`, `hotkeys`, `indicators`, …) always reflects
    /// `settings`'s current value, overwriting whatever was on disk for that key —
    /// including `schema_version`, so a file loaded pre-migration is rewritten at the
    /// current version. `existingData` is merged **after** running it through the same
    /// forward-migration chain `decode(_:)` uses, so a legacy key a migration step
    /// already folded elsewhere (e.g. v0's flat `audio_cue`) doesn't resurface as a
    /// stale duplicate. `existingData` being `nil` (first run) or unparseable (a
    /// corrupt file) simply falls back to the modeled encoding alone — merging never
    /// throws on account of `existingData`.
    static func encode(_ settings: Settings, mergingUnknownTopLevelKeysFrom existingData: Data? = nil) throws -> Data {
        let modeled = try encoder.encode(settings)
        guard
            let existingData,
            let migratedExisting = migratedTopLevelObject(from: existingData),
            let modeledObject = (try? JSONSerialization.jsonObject(with: modeled)) as? [String: Any]
        else {
            return modeled
        }

        var merged = migratedExisting
        for (key, value) in modeledObject {
            merged[key] = value
        }

        guard
            let mergedData = try? JSONSerialization.data(
                withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        else {
            return modeled
        }
        return mergedData
    }

    /// Best-effort: `existingData`'s top-level JSON object, forward-migrated to the
    /// current schema exactly as `decode(_:)` would — `nil` if the bytes aren't a
    /// parseable JSON object at all (corrupt / not JSON). Unlike `decode(_:)`, a
    /// version newer than this build understands isn't an error here: `migrate`
    /// leaves such an object untouched aside from stamping the version, which is
    /// exactly the "preserve what I don't understand" behaviour `encode` wants.
    private static func migratedTopLevelObject(from existingData: Data) -> [String: Any]? {
        guard
            let parsed = try? JSONSerialization.jsonObject(with: existingData),
            let object = parsed as? [String: Any]
        else {
            return nil
        }
        let version = (object["schema_version"] as? Int) ?? 0
        return SettingsMigrator.migrate(object, from: version)
    }

    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
