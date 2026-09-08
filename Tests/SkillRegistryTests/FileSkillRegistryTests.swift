import Foundation
import SkillManifest
import XCTest

@testable import SkillRegistry

final class FileSkillRegistryTests: XCTestCase {

    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appending(path: "aide-registry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: directory)
    }

    func testLoadsValidDiskManifest() async throws {
        try writeDisk(makeUserAutomation(id: "user_backup"))
        let registry = FileSkillRegistry(
            registryDirectory: directory, builtins: [makeManifest(id: "current_time")], watch: false)

        let ids = await registry.skills.map(\.id)

        XCTAssertEqual(ids, ["current_time", "user_backup"])
    }

    func testSkipsInvalidDiskManifestsWithoutCrashing() async throws {
        try Data("{ not json".utf8).write(to: directory.appending(path: "broken.json"))
        try writeDisk(makeManifest(id: "BAD"))
        try writeDisk(makeUserAutomation(id: "user_backup"))
        let skipped = SkipRecorder()
        let registry = FileSkillRegistry(
            registryDirectory: directory,
            builtins: [],
            watch: false,
            onSkippedDiskManifest: { url in skipped.record(url.lastPathComponent) }
        )

        let ids = await registry.skills.map(\.id)

        XCTAssertEqual(ids, ["user_backup"])
        let skippedOnInit = skipped.names
        XCTAssertEqual(Set(skippedOnInit), ["BAD.json", "broken.json"])
        XCTAssertFalse(skippedOnInit.contains("user_backup.json"))

        await registry.reload()
        let skippedOnReload = Array(skipped.names.dropFirst(skippedOnInit.count))
        XCTAssertEqual(Set(skippedOnReload), ["BAD.json", "broken.json"])
        XCTAssertFalse(skippedOnReload.contains("user_backup.json"))
    }

    func testBuiltinsWinOnIDConflict() async throws {
        var colliding = makeUserAutomation(id: "open_application")
        colliding.description = "disk copy that must lose"
        try writeDisk(colliding)
        let builtin = makeManifest(id: "open_application", description: "canonical builtin")
        let registry = FileSkillRegistry(
            registryDirectory: directory, builtins: [builtin], watch: false)

        let found = await registry.manifest(for: "open_application")

        XCTAssertEqual(found?.kind, .builtin)
        XCTAssertEqual(found?.description, "canonical builtin")
    }

    func testFileAddAppearsInGrammarAndCatalogAfterReload() async throws {
        let registry = FileSkillRegistry(registryDirectory: directory, builtins: [], watch: false)
        let emptyGrammar = await registry.routerGrammar()
        let emptyCatalog = await registry.routerPromptSkillCatalog()
        XCTAssertFalse(emptyGrammar.contains("user_backup"))
        XCTAssertFalse(emptyCatalog.contains("user_backup"))

        try writeDisk(makeUserAutomation(id: "user_backup"))
        await registry.reload()

        let grammar = await registry.routerGrammar()
        let catalog = await registry.routerPromptSkillCatalog()
        XCTAssertTrue(grammar.contains("user_backup"))
        XCTAssertTrue(catalog.contains("user_backup"))
    }

    func testFileRemoveDropsSkillFromGrammarAndCatalogAfterReload() async throws {
        try writeDisk(makeUserAutomation(id: "user_backup"))
        let registry = FileSkillRegistry(registryDirectory: directory, builtins: [], watch: false)
        let before = await registry.routerGrammar()
        XCTAssertTrue(before.contains("user_backup"))

        try fileManager.removeItem(at: directory.appending(path: "user_backup.json"))
        await registry.reload()

        let grammar = await registry.routerGrammar()
        let catalog = await registry.routerPromptSkillCatalog()
        let found = await registry.manifest(for: "user_backup")
        XCTAssertFalse(grammar.contains("user_backup"))
        XCTAssertFalse(catalog.contains("user_backup"))
        XCTAssertNil(found)
    }

    private func writeDisk(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appending(path: "\(manifest.id).json"))
    }

    private func makeUserAutomation(id: String) -> Manifest {
        Manifest(
            schemaVersion: 1,
            id: id,
            kind: .userAutomation,
            displayName: id,
            description: "A user automation for unit testing purposes.",
            utteranceExamples: [],
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            permissions: ManifestPermissions(),
            schedule: nil,
            riskTier: .confirm,
            enabled: true,
            scriptRef: "scripts/backup.sh",
            scriptSha256: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            timeoutSeconds: 60,
            failureState: FailureState(),
            createdAt: nil,
            updatedAt: nil,
            generatedBy: .manual
        )
    }
}

/// Thread-safe recorder for skipped-disk-manifest callbacks (init and reload may hop threads).
private final class SkipRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(name)
    }

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
