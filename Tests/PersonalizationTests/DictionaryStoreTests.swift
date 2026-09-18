import XCTest

@testable import Personalization

final class DictionaryStoreTests: XCTestCase {

    var directory: URL!
    let fileManager = FileManager.default
    let now = ISO8601DateFormatter().date(from: "2026-09-15T10:00:00Z") ?? Date()

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appending(path: "aide-dictionary-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: directory)
    }

    var fileURL: URL { directory.appending(path: "dictionary.json") }

    func makeStore(config: BudgetConfig = .default) -> DictionaryStore {
        let now = self.now
        return DictionaryStore(fileURL: fileURL, clock: { now }, config: config)
    }

    func testRecordExplicitPersistsAndReloads() async throws {
        let store = makeStore()
        try await store.record(mishearing: "cooper nettie's", correct: "Kubernetes", source: .explicit)

        let live = await store.allEntries()
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.correctTerm, "Kubernetes")
        XCTAssertEqual(live.first?.mishearings, ["cooper nettie's"])
        XCTAssertEqual(live.first?.occurrenceCount, 1)
        XCTAssertEqual(live.first?.source, .explicit)
        XCTAssertTrue(live.first?.promoted ?? false)
        XCTAssertEqual(live.first?.createdAt, now)
        XCTAssertEqual(live.first?.lastUsedAt, now)

        let data = try Data(contentsOf: fileURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 1)

        let reloaded = makeStore()
        await reloaded.load()
        let restored = await reloaded.allEntries()
        XCTAssertEqual(restored.map(\.correctTerm), ["Kubernetes"])
        XCTAssertEqual(restored.map(\.id), live.map(\.id))
        let promoted = await reloaded.promotedEntries()
        XCTAssertEqual(promoted.count, 1)
    }

    func testCaseInsensitiveMergeAddsMishearing() async throws {
        let store = makeStore()
        try await store.record(mishearing: "cooper nettie's", correct: "Kubernetes", source: .explicit)
        try await store.record(mishearing: "kubernetis", correct: "kubernetes", source: .explicit)

        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.correctTerm, "Kubernetes")
        XCTAssertEqual(entries.first?.mishearings, ["cooper nettie's", "kubernetis"])
        XCTAssertEqual(entries.first?.occurrenceCount, 2)
    }

    func testLoadMissingFileDoesNotWrite() async throws {
        let store = makeStore()
        await store.load()
        XCTAssertFalse(fileManager.fileExists(atPath: fileURL.path))
        let entries = await store.allEntries()
        XCTAssertEqual(entries, [])
    }

    func testRemoveByIdGoneAfterPersistAndReload() async throws {
        let store = makeStore()
        try await store.record(mishearing: "cooper nettie's", correct: "Kubernetes", source: .explicit)
        try await store.record(mishearing: "sam rit", correct: "Sumrit", source: .explicit)

        let live = await store.allEntries()
        let kubernetesID = try XCTUnwrap(live.first { $0.correctTerm == "Kubernetes" }?.id)
        try await store.remove(id: kubernetesID)

        let remaining = await store.allEntries()
        XCTAssertEqual(remaining.map(\.correctTerm), ["Sumrit"])
        XCTAssertFalse(remaining.contains { $0.id == kubernetesID })

        let reloaded = makeStore()
        await reloaded.load()
        let restored = await reloaded.allEntries()
        XCTAssertEqual(restored.map(\.correctTerm), ["Sumrit"])
        XCTAssertFalse(restored.contains { $0.id == kubernetesID })
    }

    func testUpsertInsertsOrReplacesById() async throws {
        let store = makeStore()
        let inserted = DictionaryEntry(
            id: "e_k8s",
            correctTerm: "Kubernetes",
            mishearings: ["cooper nettie's"],
            occurrenceCount: 1,
            promoted: false,
            source: .explicit,
            createdAt: now,
            lastUsedAt: now)
        try await store.upsert(inserted)

        let afterInsert = await store.allEntries()
        XCTAssertEqual(afterInsert.map(\.id), ["e_k8s"])
        XCTAssertEqual(afterInsert.first?.correctTerm, "Kubernetes")
        XCTAssertEqual(afterInsert.first?.mishearings, ["cooper nettie's"])

        let replacement = DictionaryEntry(
            id: "e_k8s",
            correctTerm: "k8s",
            mishearings: ["kubernetis"],
            occurrenceCount: 3,
            promoted: false,
            source: .explicit,
            createdAt: now,
            lastUsedAt: now)
        try await store.upsert(replacement)

        let afterReplace = await store.allEntries()
        XCTAssertEqual(afterReplace.count, 1)
        XCTAssertEqual(afterReplace.first?.id, "e_k8s")
        XCTAssertEqual(afterReplace.first?.correctTerm, "k8s")
        XCTAssertEqual(afterReplace.first?.mishearings, ["kubernetis"])
        XCTAssertEqual(afterReplace.first?.occurrenceCount, 3)

        let reloaded = makeStore()
        await reloaded.load()
        let restored = await reloaded.allEntries()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, "e_k8s")
        XCTAssertEqual(restored.first?.correctTerm, "k8s")
        XCTAssertEqual(restored.first?.mishearings, ["kubernetis"])
        XCTAssertEqual(restored.first?.occurrenceCount, 3)
    }

    func testReplaceAllClearsFile() async throws {
        let store = makeStore()
        try await store.record(mishearing: "cooper nettie's", correct: "Kubernetes", source: .explicit)
        let before = await store.allEntries()
        XCTAssertEqual(before.count, 1)

        try await store.replaceAll([])

        let cleared = await store.allEntries()
        XCTAssertEqual(cleared, [])
        let reloaded = makeStore()
        await reloaded.load()
        let restoredEmpty = await reloaded.allEntries()
        XCTAssertEqual(restoredEmpty, [])
        XCTAssertTrue(fileManager.fileExists(atPath: fileURL.path))
    }

    func testAddExplicitEmptyMishearingCreatesPromotedEntry() async throws {
        let store = makeStore()
        try await store.addExplicit(correctTerm: "Kubernetes", mishearing: "")

        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.correctTerm, "Kubernetes")
        XCTAssertEqual(entries.first?.mishearings, [])
        XCTAssertEqual(entries.first?.source, .explicit)
        XCTAssertTrue(entries.first?.promoted ?? false)
        XCTAssertEqual(entries.first?.createdAt, now)
        XCTAssertEqual(entries.first?.lastUsedAt, now)
    }

    func testAddExplicitEmptyCorrectTermThrowsInvalidTermPair() async {
        let store = makeStore()

        do {
            try await store.addExplicit(correctTerm: "", mishearing: "")
            XCTFail("expected DictionaryStoreError.invalidTermPair")
        } catch let error as DictionaryStoreError {
            XCTAssertEqual(error, .invalidTermPair)
        } catch {
            XCTFail("expected DictionaryStoreError.invalidTermPair, got \(error)")
        }

        do {
            try await store.addExplicit(correctTerm: "   ", mishearing: "")
            XCTFail("expected DictionaryStoreError.invalidTermPair")
        } catch let error as DictionaryStoreError {
            XCTAssertEqual(error, .invalidTermPair)
        } catch {
            XCTFail("expected DictionaryStoreError.invalidTermPair, got \(error)")
        }
    }

    func testAddExplicitNonEmptyMishearingPersistsPair() async throws {
        let store = makeStore()
        try await store.addExplicit(correctTerm: "Kubernetes", mishearing: "cooper nettie's")

        let live = await store.allEntries()
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.correctTerm, "Kubernetes")
        XCTAssertEqual(live.first?.mishearings, ["cooper nettie's"])
        XCTAssertEqual(live.first?.occurrenceCount, 1)
        XCTAssertEqual(live.first?.source, .explicit)
        XCTAssertTrue(live.first?.promoted ?? false)

        let reloaded = makeStore()
        await reloaded.load()
        let restored = await reloaded.allEntries()
        XCTAssertEqual(restored.map(\.correctTerm), ["Kubernetes"])
        XCTAssertEqual(restored.first?.mishearings, ["cooper nettie's"])
    }
}
