import XCTest

@testable import Personalization

/// A concurrency-safe call counter for clock spies. Mirrors the `NSLock`-guarded
/// spy pattern used by `FakeSidecarTiming` in `Tests/LLMRuntimeTests`.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Returns the counter's value before incrementing it.
    func incrementAndGetPrevious() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let previous = count
        count += 1
        return previous
    }
}

extension DictionaryStoreTests {

    func testHardCapUsesDocumentValueNotConfig() async throws {
        let fixture = Data(
            """
            {
              "schema_version": 1,
              "hard_cap": 5,
              "entries": []
            }
            """.utf8)
        try fixture.write(to: fileURL)

        // Config's hardCap (500) must NOT win over the loaded document's hard_cap (5).
        let store = makeStore(config: .default)
        await store.load()

        for index in 0..<6 {
            try await store.record(
                mishearing: "mishearing\(index)", correct: "Term\(index)", source: .explicit)
        }

        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 5, "eviction should cap at the document's hard_cap (5), not config's (500)")

        let data = try Data(contentsOf: fileURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["hard_cap"] as? Int, 5, "persist must not overwrite the loaded hard_cap with config's")
    }

    func testAddExplicitEmptyMishearingFoundBranchBumpsCountAndRefreshesTimeWithoutPollutingMishearings()
        async throws
    {
        let callCount = LockedCounter()
        let times = [now, now.addingTimeInterval(60)]
        let store = DictionaryStore(
            fileURL: fileURL,
            clock: {
                let index = callCount.incrementAndGetPrevious()
                return times[min(index, times.count - 1)]
            })

        try await store.addExplicit(correctTerm: "Kubernetes", mishearing: "")
        try await store.addExplicit(correctTerm: "kubernetes", mishearing: "")

        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.correctTerm, "Kubernetes")
        XCTAssertEqual(entries.first?.mishearings, [], "empty-mishearing path must not append \"\"")
        XCTAssertEqual(entries.first?.occurrenceCount, 2)
        XCTAssertEqual(entries.first?.lastUsedAt, times[1], "lastUsedAt must be refreshed on the second call")
        XCTAssertEqual(entries.first?.source, .explicit)
    }

    func testGenerationIncrementsOnEveryMutatingCallAndIsStableAcrossReads() async throws {
        let store = makeStore()
        let initial = await store.generation()

        try await store.record(mishearing: "cooper nettie's", correct: "Kubernetes", source: .explicit)
        let afterRecord = await store.generation()
        XCTAssertEqual(afterRecord, initial + 1, "record must bump the generation")

        try await store.addExplicit(correctTerm: "Sumrit", mishearing: "sam rit")
        let afterAddExplicit = await store.generation()
        XCTAssertEqual(afterAddExplicit, afterRecord + 1, "addExplicit must bump the generation")

        // Reads must never bump the generation.
        _ = await store.allEntries()
        _ = await store.promotedEntries()
        let afterReads = await store.generation()
        XCTAssertEqual(
            afterReads, afterAddExplicit,
            "allEntries/promotedEntries must not bump the generation")

        let allEntriesAfterReads = await store.allEntries()
        let kubernetesID = try XCTUnwrap(
            allEntriesAfterReads.first { $0.correctTerm == "Kubernetes" }?.id)
        try await store.remove(id: kubernetesID)
        let afterRemove = await store.generation()
        XCTAssertEqual(afterRemove, afterAddExplicit + 1, "remove must bump the generation")

        try await store.upsert(
            DictionaryEntry(
                id: "e_new",
                correctTerm: "NewTerm",
                mishearings: [],
                occurrenceCount: 1,
                promoted: false,
                source: .explicit,
                createdAt: now,
                lastUsedAt: now))
        let afterUpsert = await store.generation()
        XCTAssertEqual(afterUpsert, afterRemove + 1, "upsert must bump the generation")

        try await store.replaceAll([])
        let afterReplaceAll = await store.generation()
        XCTAssertEqual(afterReplaceAll, afterUpsert + 1, "replaceAll must bump the generation")
    }
}
