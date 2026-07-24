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
    static func encode(_ settings: Settings) throws -> Data {
        try encoder.encode(settings)
    }

    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
