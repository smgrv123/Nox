import Foundation

/// The on-disk storage tree under `~/Library/Application Support/Aide/`
/// (User Story 33; docs/05-lld.md §2.7). Everything Aide persists lives here in
/// human-readable files so the user can find, inspect, and back it up.
///
/// This is the pure, testable core: it computes every path from an **injected**
/// `root` URL and creates the directory slots idempotently. The only effectful
/// shell is `applicationSupport(fileManager:)`, which resolves the real Application
/// Support location — tests inject a temp root instead, so they never touch the
/// user's actual data (specs/P1 §"Testing Decisions").
public struct StorageLayout: Sendable {

    /// The `…/Aide/` root. All slots below hang off it.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: - File slots (owned by later phases; the tree only guarantees the root)

    /// Schema-versioned settings document (§2.5). Written by Phase 3, secrets excluded.
    public var settingsFile: URL { file("settings.json") }
    /// Personalization dictionary (§2.3), owned by P5.
    public var dictionaryFile: URL { file("dictionary.json") }

    // MARK: - Directory slots (§2.7)

    /// One manifest per skill/automation (§2.1).
    public var registryDirectory: URL { directory("registry") }
    /// Frozen user scripts (§7.2), `0700`.
    public var scriptsDirectory: URL { directory("scripts") }
    /// Generated `router.gbnf` (§2.2).
    public var grammarDirectory: URL { directory("grammar") }
    /// Append-only command history, date-partitioned (§2.6).
    public var historyDirectory: URL { directory("history") }
    /// Plain-text + JSONL logs (§2.6).
    public var logsDirectory: URL { directory("logs") }
    /// Per-run script execution logs (§2.6), nested under `logs/`.
    public var execLogsDirectory: URL { logsDirectory.appending(path: "exec", directoryHint: .isDirectory) }
    /// Generated launchd `.plist` snapshots (§5.3).
    public var launchdDirectory: URL { directory("launchd") }
    /// Downloaded model blobs (§2.7); user-discoverable, reported in Settings.
    public var modelsDirectory: URL { directory("models") }

    // MARK: - Named files within slots

    /// Human-readable application log (§2.6 / §9).
    public var appLogFile: URL { logsDirectory.appending(path: "app.log") }
    /// Routing-confidence calibration log (§4.2 / §7); spared by a scoped wipe.
    public var calibrationLogFile: URL { logsDirectory.appending(path: "calibration.jsonl") }
    /// Sidecar (`llama-server`) stdout/stderr (§3.4).
    public var sidecarLogFile: URL { logsDirectory.appending(path: "sidecar.log") }

    /// The command-history file for a given day: `history/commands-YYYY-MM-DD.jsonl`
    /// (§2.6), dated in UTC so a day boundary is stable regardless of local time.
    public func historyFile(for date: Date) -> URL {
        historyDirectory.appending(path: "commands-\(Self.dayFormatter.string(from: date)).jsonl")
    }

    // MARK: - Tree creation

    /// Every directory the tree guarantees, root first. `settings.json` /
    /// `dictionary.json` are deliberately absent — they are file slots created by
    /// their owning phases, not empty placeholders.
    public var directories: [URL] {
        [
            root,
            registryDirectory,
            scriptsDirectory,
            grammarDirectory,
            historyDirectory,
            logsDirectory,
            execLogsDirectory,
            launchdDirectory,
            modelsDirectory,
        ]
    }

    /// Create every missing directory slot. Idempotent and safe to run on every
    /// launch: `withIntermediateDirectories` never errors on an existing directory
    /// and never disturbs files already inside one.
    public func createTree(using fileManager: FileManager = .default) throws {
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Resolve the real `~/Library/Application Support/Aide/` layout. This is the
    /// thin effectful shell; the tree/path logic above stays pure and injected.
    public static func applicationSupport(fileManager: FileManager = .default) throws -> StorageLayout {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false)
        return StorageLayout(root: base.appending(path: "Aide", directoryHint: .isDirectory))
    }

    // MARK: - Helpers

    private func directory(_ name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
    }

    private func file(_ name: String) -> URL {
        root.appending(path: name)
    }

    private static let dayFormatter: DateFormatter = UTCDateFormatter.make(
        dateFormat: "yyyy-MM-dd",
        calendar: Calendar(identifier: .iso8601))
}
