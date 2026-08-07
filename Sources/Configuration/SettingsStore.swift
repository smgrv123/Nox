import Foundation
import Persistence

/// The load/save façade for `settings.json` (docs/05-lld.md §2.5). It binds the pure
/// codec (`SettingsCodec`) to a concrete file URL and Phase 2's `AtomicFileWriter`,
/// and owns the **resilience policy**:
///
/// - **Missing file** → safe defaults (first run, or after a wipe).
/// - **Corrupt / unreadable file** → safe defaults, and the bad bytes are **backed
///   up** to a sibling (nothing is silently destroyed) rather than crashing
///   (User Story 38).
/// - **Older `schema_version`** → migrated forward on load with no data loss (§1.2).
///
/// `load()` never throws — it always yields a usable `Settings`. Every non-nominal
/// outcome is reported through the injected `signal` closure so the app can log it
/// (the app wires this to `app.log`); the store never swallows a fallback silently.
/// Writes go through `AtomicFileWriter`, so a reader never sees a half-written file
/// and an interrupted save leaves the previous file intact (§2.7 "Atomicity (MUST)").
public struct SettingsStore {

    /// A non-nominal load outcome, surfaced so it can be logged (never swallowed).
    public enum Signal: Equatable {
        /// No file on disk yet — defaults were used (first run / post-wipe).
        case missing
        /// The file was at an older schema version and was migrated forward.
        case migrated(from: Int)
        /// The file was unreadable; defaults were used and the bad bytes were moved
        /// aside to `backupURL` (`nil` if even the backup could not be written).
        case recovered(backupURL: URL?)
    }

    private let fileURL: URL
    private let writer: AtomicFileWriter
    private let fileManager: FileManager
    private let now: () -> Date
    private let signal: (Signal) -> Void

    /// - Parameters:
    ///   - fileURL: where the document lives — inject a temp URL in tests, pass
    ///     `StorageLayout.settingsFile` in the app.
    ///   - now: injected clock, used only to name backup files deterministically.
    ///   - signal: reports missing / migrated / recovered outcomes for logging.
    public init(
        fileURL: URL,
        writer: AtomicFileWriter = AtomicFileWriter(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = { Date() },
        signal: @escaping (Signal) -> Void = { _ in }
    ) {
        self.fileURL = fileURL
        self.writer = writer
        self.fileManager = fileManager
        self.now = now
        self.signal = signal
    }

    /// Load the settings, applying the resilience policy above. Always returns a
    /// usable value; reports any fallback through `signal`.
    public func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else {
            signal(.missing)
            return .defaults
        }

        do {
            let decoded = try SettingsCodec.decode(data)
            if let from = decoded.migratedFrom {
                signal(.migrated(from: from))
            }
            return decoded.settings
        } catch {
            signal(.recovered(backupURL: backUpUnreadableFile(data)))
            return .defaults
        }
    }

    /// Atomically persist the settings (temp-sibling + `rename(2)`, §2.7). Any
    /// top-level JSON block already on disk that the current `Settings` model doesn't
    /// represent is preserved verbatim (§2.5: `settings.json` is one document holding
    /// ALL config blocks, not just the ones this build models) — see
    /// `SettingsCodec.encode(_:mergingUnknownTopLevelKeysFrom:)`.
    public func save(_ settings: Settings) throws {
        let existing = try? Data(contentsOf: fileURL)
        try writer.write(try SettingsCodec.encode(settings, mergingUnknownTopLevelKeysFrom: existing), to: fileURL)
    }

    /// Move an unreadable file aside so its contents are preserved for inspection and
    /// the next `save` starts clean. Best-effort: if the backup can't be written we
    /// leave the original in place and report `nil` (defaults are still returned).
    private func backUpUnreadableFile(_ data: Data) -> URL? {
        let backupName = "\(fileURL.lastPathComponent).corrupt-\(Self.backupStamp.string(from: now()))"
        let backupURL = fileURL.deletingLastPathComponent().appending(path: backupName)
        do {
            try writer.write(data, to: backupURL)
            try? fileManager.removeItem(at: fileURL)
            return backupURL
        } catch {
            return nil
        }
    }

    /// Filesystem-safe UTC stamp for backup names (no colons): `20260724T205040Z`.
    private static let backupStamp: DateFormatter = UTCDateFormatter.make(
        dateFormat: "yyyyMMdd'T'HHmmss'Z'")
}
