import Foundation
import SkillManifest
import os

/// Filesystem-backed ``SkillRegistering``: disk `*.json` manifests merged with
/// an injected built-in catalog. Built-ins win on ID conflict. Invalid or
/// non-`user_automation` disk files are skipped — they never crash the registry.
///
/// Directory changes re-scan via ``reload()``. Production passes `watch: true`
/// so a `DispatchSource` triggers reload; tests pass `watch: false` and call
/// ``reload()`` after writing files.
public actor FileSkillRegistry: SkillRegistering {
    private let directory: URL
    private let builtins: [Manifest]
    private let onSkippedDiskManifest: @Sendable (URL) -> Void
    private var inMemoryRegistry: InMemorySkillRegistry
    private var watchSource: DispatchSourceFileSystemObject?

    public init(
        registryDirectory: URL,
        builtins: [Manifest],
        watch: Bool = true,
        onSkippedDiskManifest: @escaping @Sendable (URL) -> Void = { url in
            Logger(subsystem: "com.aide.Aide", category: "SkillRegistry").warning(
                "Skipping invalid disk manifest: \(url.lastPathComponent, privacy: .public)")
        }
    ) {
        self.directory = registryDirectory
        self.builtins = builtins
        self.onSkippedDiskManifest = onSkippedDiskManifest
        self.inMemoryRegistry = Self.makeInMemoryRegistry(
            directory: registryDirectory,
            builtins: builtins,
            onSkippedDiskManifest: onSkippedDiskManifest
        )
        if watch {
            Task { await self.startWatching() }
        }
    }

    public func reload() {
        inMemoryRegistry = Self.makeInMemoryRegistry(
            directory: directory,
            builtins: builtins,
            onSkippedDiskManifest: onSkippedDiskManifest
        )
    }

    public var skills: [Manifest] {
        get async { await inMemoryRegistry.skills }
    }

    public func manifest(for skillID: String) async -> Manifest? {
        await inMemoryRegistry.manifest(for: skillID)
    }

    public func routerGrammar() async -> String {
        await inMemoryRegistry.routerGrammar()
    }

    public func routerPromptSkillCatalog() async -> String {
        await inMemoryRegistry.routerPromptSkillCatalog()
    }

    public func validate(
        parameters: JSONValue,
        for skillID: String
    ) async -> Result<Void, ParameterValidationError> {
        await inMemoryRegistry.validate(parameters: parameters, for: skillID)
    }

    private func startWatching() {
        let path = directory.path
        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { await self?.reload() }
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.resume()
        watchSource = source
    }

    deinit {
        watchSource?.cancel()
    }

    private static func makeInMemoryRegistry(
        directory: URL,
        builtins: [Manifest],
        onSkippedDiskManifest: @Sendable (URL) -> Void
    ) -> InMemorySkillRegistry {
        InMemorySkillRegistry(
            manifests: merge(
                builtins: builtins,
                disk: loadDisk(directory: directory, onSkippedDiskManifest: onSkippedDiskManifest)
            )
        )
    }

    private static func merge(builtins: [Manifest], disk: [Manifest]) -> [Manifest] {
        let builtinIDs = Set(builtins.map(\.id))
        return builtins + disk.filter { !builtinIDs.contains($0.id) }
    }

    private static func loadDisk(
        directory: URL,
        onSkippedDiskManifest: @Sendable (URL) -> Void
    ) -> [Manifest] {
        let fileManager = FileManager.default
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        return
            urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                decodeUserAutomation(
                    from: url, decoder: decoder, onSkippedDiskManifest: onSkippedDiskManifest)
            }
    }

    private static func decodeUserAutomation(
        from url: URL,
        decoder: JSONDecoder,
        onSkippedDiskManifest: @Sendable (URL) -> Void
    ) -> Manifest? {
        guard let data = try? Data(contentsOf: url),
            let manifest = try? decoder.decode(Manifest.self, from: data),
            manifest.kind == .userAutomation,
            ManifestValidation.validate(manifest).isEmpty
        else {
            onSkippedDiskManifest(url)
            return nil
        }
        return manifest
    }
}
