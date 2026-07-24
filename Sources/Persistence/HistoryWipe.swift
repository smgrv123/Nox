import Foundation

/// The scoped one-click **"Wipe all history"** operation (User Story 34;
/// docs/05-lld.md §2.6 "Retention & wipe", docs/04-hld.md §16.2).
///
/// A history wipe clears exactly the user's *trail* — transcripts, command history,
/// and script execution logs — while leaving their *configuration* intact. Per the
/// locked storage rule it removes:
///
/// - everything under `history/` (the command-history JSONL, which carries the
///   transcripts),
/// - everything under `logs/exec/` (per-run script logs and their `.out`/`.err`
///   capture siblings), and any loose `logs/*.out`/`.err`,
/// - and **only when separately chosen** (`Options.includeCalibrationLog`),
///   `logs/calibration.jsonl` — a distinct file precisely so a wipe can spare it.
///
/// It never touches `settings.json`, `dictionary.json`, `registry/`, `scripts/`,
/// `grammar/`, `launchd/`, `models/`, or the non-history logs (`app.log`,
/// `sidecar.log`). This is a data-loss boundary: over-deleting is the failure mode,
/// so the scope is expressed as a pure, exhaustively tested predicate
/// (`isInScope`) rather than baked implicitly into the deletion loop.
///
/// The scope logic is pure and testable; only `perform` touches the filesystem,
/// and it operates on the **injected** `StorageLayout.root` so tests run against a
/// throwaway temp tree (specs/P1 §"Testing Decisions").
public struct HistoryWipe: Sendable {

    /// What a wipe includes beyond the always-cleared history set. Every extra is
    /// opt-in and defaults to *off*, so the plain "Wipe all history" is minimal.
    public struct Options: Sendable, Equatable {
        /// Also clear `logs/calibration.jsonl` (spared by default — §2.6).
        public var includeCalibrationLog: Bool

        public init(includeCalibrationLog: Bool = false) {
            self.includeCalibrationLog = includeCalibrationLog
        }
    }

    private let layout: StorageLayout

    public init(layout: StorageLayout) {
        self.layout = layout
    }

    // MARK: - Scope policy (pure, no I/O)

    /// Whether a history wipe under `options` deletes `url`. Pure function of the
    /// path + layout + options — the single source of truth for what "in scope"
    /// means, and the heart the tests pin down. No filesystem access.
    public func isInScope(_ url: URL, options: Options = .init()) -> Bool {
        // Command history (transcripts) and script execution logs, whole subtrees.
        if isDescendant(url, of: layout.historyDirectory) { return true }
        if isDescendant(url, of: layout.execLogsDirectory) { return true }

        // Loose siblings directly under logs/: script stdout/stderr captures, plus
        // the opt-in calibration log. app.log / sidecar.log fall through as preserved.
        if hasParent(url, layout.logsDirectory) {
            let ext = url.pathExtension.lowercased()
            if ext == "out" || ext == "err" { return true }
            if options.includeCalibrationLog, sameFile(url, layout.calibrationLogFile) { return true }
        }
        return false
    }

    // MARK: - Wipe (I/O against the injected tree)

    /// The exact set of existing paths a wipe would remove, without mutating
    /// anything. Useful for a "this will delete N files" confirmation and for
    /// asserting scope in tests.
    public func plannedRemovals(
        options: Options = .init(),
        using fileManager: FileManager = .default
    ) -> [URL] {
        var removals = children(of: layout.historyDirectory, using: fileManager)
        removals += children(of: layout.execLogsDirectory, using: fileManager)
        removals += children(of: layout.logsDirectory, using: fileManager)
            .filter { isInScope($0, options: options) }
        return removals
    }

    /// Perform the wipe: delete every in-scope path, leaving the emptied `history/`
    /// and `logs/exec/` slot directories in place (only their *contents* go, so the
    /// tree invariant from `createTree` still holds). Idempotent and tolerant of a
    /// missing tree — a wipe with nothing to remove is a success, not an error, so
    /// the operation never fails silently on the user (User Story 38).
    ///
    /// - Returns: the paths actually removed, in deletion order.
    @discardableResult
    public func perform(
        options: Options = .init(),
        using fileManager: FileManager = .default
    ) throws -> [URL] {
        let removals = plannedRemovals(options: options, using: fileManager)
        for url in removals {
            try fileManager.removeItem(at: url)
        }
        return removals
    }

    // MARK: - Helpers (pure path arithmetic)

    /// Immediate children of `directory`, or `[]` if it does not exist. A missing
    /// slot is normal (the tree is created lazily), so absence is not an error.
    private func children(of directory: URL, using fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    /// True iff `url` sits strictly inside `ancestor` (compared on normalized path
    /// components, so a trailing slash or `.`/`..` never changes the answer).
    private func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        return urlComponents.count > ancestorComponents.count
            && Array(urlComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }

    /// True iff `url`'s immediate parent directory is `parent`.
    private func hasParent(_ url: URL, _ parent: URL) -> Bool {
        sameFile(url.deletingLastPathComponent(), parent)
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}
