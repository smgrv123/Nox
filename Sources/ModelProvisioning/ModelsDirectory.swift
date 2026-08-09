import Foundation

/// Resolves the **user-discoverable** models directory and the per-blob paths under it
/// (docs/05-lld.md §2.7; User Story 16). Model blobs live at `…/Aide/models/`; the
/// directory is surfaced in Settings with a reveal-in-Finder affordance so the user can
/// see what Aide put on disk and reclaim the space.
///
/// Pure path computation over an **injected** root — tests pass a temp directory, so they
/// never touch the real `~/Library`. The `applicationSupport(…)` resolver is the only thin
/// effectful shell (it mirrors `Persistence.StorageLayout`'s `…/Aide/` root; §2.7 allows
/// the blobs to live under `~/Library/Caches/Aide/models/` instead, kept discoverable).
public struct ModelsDirectory: Sendable {
    /// The models slot's directory name under the app container.
    public static let directoryName = "models"
    /// The resumable-download bookkeeping file (`ResumePlan` / `DownloadStateStore`).
    public static let downloadStateFilename = ".download-state.json"

    /// The resolved `…/models/` directory.
    public let url: URL

    /// Resolve `models/` under an injected app container root (`…/Aide/`).
    public init(containerRoot: URL) {
        self.url = containerRoot.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    /// Adopt an already-resolved models directory (e.g. a Caches-backed location).
    public init(resolved url: URL) {
        self.url = url
    }

    /// Absolute URL of a descriptor's blob, from its models-relative path.
    public func blobURL(for descriptor: ModelDescriptor) -> URL {
        url.appending(path: descriptor.onDiskRelativePath)
    }

    /// Absolute URL of `.download-state.json`.
    public var downloadStateURL: URL {
        url.appending(path: Self.downloadStateFilename)
    }

    /// The directory to reveal in Finder for the Settings affordance (§2.7).
    public var revealInFinderURL: URL { url }

    /// Create the directory if missing. Idempotent (`withIntermediateDirectories`).
    public func create(using fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Resolve the real `~/Library/Application Support/Aide/models/` location. The thin
    /// effectful shell; the path logic above stays pure and injected.
    public static func applicationSupport(fileManager: FileManager = .default) throws -> ModelsDirectory {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false)
        return ModelsDirectory(containerRoot: base.appending(path: "Aide", directoryHint: .isDirectory))
    }
}
