import XCTest

@testable import Personalization

final class BiasPromptBudgetTests: XCTestCase {

    func testStopsBeforeExceedingBudget() {
        // FakeCounter: max(1, count/4). "abcd" → 1; "abcd, efgh" → 2; third → 4.
        let filled = BiasPromptBudget.append(
            ["abcd", "efgh", "ijkl"],
            onto: [],
            counter: FakeCounter(),
            tokenBudget: 2)
        XCTAssertEqual(filled, ["abcd", "efgh"])
    }

    func testHigherScoreFirst() {
        let now = Date()
        let halfLifeDays = 14.0
        let recent = entry(term: "zeta", count: 10, lastUsed: now)
        let stale = entry(
            term: "alpha",
            count: 10,
            lastUsed: now.addingTimeInterval(-halfLifeDays * 86_400))
        let ranked = BiasPromptBudget.rankedCorrectTerms(
            [stale, recent],
            now: now,
            halfLifeDays: halfLifeDays)
        XCTAssertEqual(ranked, ["zeta", "alpha"])

        let tiedA = entry(term: "beta", count: 1, lastUsed: now)
        let tiedB = entry(term: "alpha", count: 1, lastUsed: now)
        let tied = BiasPromptBudget.rankedCorrectTerms(
            [tiedA, tiedB],
            now: now,
            halfLifeDays: halfLifeDays)
        XCTAssertEqual(tied, ["alpha", "beta"])
    }

    private func entry(term: String, count: Int, lastUsed: Date) -> DictionaryEntry {
        DictionaryEntry(
            id: term,
            correctTerm: term,
            mishearings: [],
            occurrenceCount: count,
            promoted: true,
            source: .explicit,
            createdAt: lastUsed,
            lastUsedAt: lastUsed)
    }
}
