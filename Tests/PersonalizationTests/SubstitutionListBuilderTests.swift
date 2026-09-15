import XCTest

@testable import Personalization

final class SubstitutionListBuilderTests: XCTestCase {

    func testOnlyPromoted() {
        let now = Date()
        let promoted = entry(
            id: "k8s", term: "Kubernetes", mishearings: ["cooper nettie's"],
            promoted: true, count: 3, lastUsed: now)
        let unpublished = entry(
            id: "sumrit", term: "Sumrit", mishearings: ["sam rit"],
            promoted: false, count: 99, lastUsed: now)

        let list = SubstitutionListBuilder.build(
            promotedEntries: [unpublished, promoted],
            now: now)

        XCTAssertTrue(list.contains("`cooper nettie's` -> `Kubernetes`"))
        XCTAssertFalse(list.contains("Sumrit"))
        XCTAssertFalse(list.contains("sam rit"))
    }

    func testTopNCap() {
        let now = Date()
        let topNTwo = BudgetConfig(
            hardCap: 500,
            tokenBudget: 200,
            substitutionTopN: 2,
            recencyHalfLifeDays: 14,
            promoteMin: 2,
            appNameCap: 50)

        let highWithMany = entry(
            id: "a", term: "Alpha",
            mishearings: ["alfa", "al pha", "alphaa"],
            promoted: true, count: 10, lastUsed: now)
        let lower = entry(
            id: "b", term: "Beta", mishearings: ["beeta"],
            promoted: true, count: 5, lastUsed: now)

        let pairCapped = SubstitutionListBuilder.build(
            promotedEntries: [lower, highWithMany],
            config: topNTwo,
            now: now)

        XCTAssertEqual(
            pairCapped,
            "`alfa` -> `Alpha`\n`al pha` -> `Alpha`")
        XCTAssertFalse(pairCapped.contains("Beta"))
        XCTAssertFalse(pairCapped.contains("beeta"))
        XCTAssertFalse(pairCapped.contains("alphaa"))

        let high = entry(
            id: "a", term: "Alpha", mishearings: ["alfa"],
            promoted: true, count: 10, lastUsed: now)
        let mid = entry(
            id: "b", term: "Beta", mishearings: ["beeta"],
            promoted: true, count: 5, lastUsed: now)
        let low = entry(
            id: "c", term: "Gamma", mishearings: ["gama"],
            promoted: true, count: 1, lastUsed: now)

        let list = SubstitutionListBuilder.build(
            promotedEntries: [low, mid, high],
            config: topNTwo,
            now: now)

        XCTAssertEqual(
            list,
            "`alfa` -> `Alpha`\n`beeta` -> `Beta`")
        XCTAssertFalse(list.contains("Gamma"))
    }

    func testEmptyEntriesReturnsNone() {
        let list = SubstitutionListBuilder.build(
            promotedEntries: [],
            now: Date())

        XCTAssertEqual(list, "none.")
    }

    func testTopNZeroReturnsNone() {
        let now = Date()
        let promoted = entry(
            id: "k8s", term: "Kubernetes", mishearings: ["cooper nettie's"],
            promoted: true, count: 3, lastUsed: now)

        let list = SubstitutionListBuilder.build(
            promotedEntries: [promoted],
            config: BudgetConfig(
                hardCap: 500,
                tokenBudget: 200,
                substitutionTopN: 0,
                recencyHalfLifeDays: 14,
                promoteMin: 2,
                appNameCap: 50),
            now: now)

        XCTAssertEqual(list, "none.")
    }

    private func entry(
        id: String,
        term: String,
        mishearings: [String],
        promoted: Bool = true,
        count: Int,
        lastUsed: Date
    ) -> DictionaryEntry {
        DictionaryEntry(
            id: id,
            correctTerm: term,
            mishearings: mishearings,
            occurrenceCount: count,
            promoted: promoted,
            source: .explicit,
            createdAt: lastUsed,
            lastUsedAt: lastUsed)
    }
}
