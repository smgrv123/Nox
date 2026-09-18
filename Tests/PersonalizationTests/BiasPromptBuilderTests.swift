import XCTest

@testable import Personalization

final class BiasPromptBuilderTests: XCTestCase {

    func testDictionaryTermsPrecedeAppNames() {
        let now = Date()
        let prompt = BiasPromptBuilder().build(
            promotedEntries: [entry(term: "Kubernetes", lastUsed: now)],
            extraPhrases: ["Ghostty", "Safari"],
            counter: FakeCounter(),
            now: now)
        XCTAssertEqual(prompt, "Kubernetes, Ghostty, Safari")
    }

    func testNilWhenNothingFits() {
        let now = Date()
        let overBudget = BiasPromptBuilder().build(
            promotedEntries: [entry(term: "Kubernetes", lastUsed: now)],
            extraPhrases: ["Ghostty"],
            counter: FakeCounter(),
            config: BudgetConfig(
                hardCap: 500,
                tokenBudget: 0,
                substitutionTopN: 40,
                recencyHalfLifeDays: 14,
                promoteMin: 2,
                appNameCap: 50),
            now: now)
        XCTAssertNil(overBudget)

        let empty = BiasPromptBuilder().build(
            promotedEntries: [],
            extraPhrases: [],
            counter: FakeCounter(),
            now: now)
        XCTAssertNil(empty)
    }

    func testAppNameCapAppliesToExtraPhrasesOnly() {
        let now = Date()
        let appNameCap = 2
        let prompt = BiasPromptBuilder().build(
            promotedEntries: [
                entry(term: "Alpha", lastUsed: now),
                entry(term: "Beta", lastUsed: now),
                entry(term: "Gamma", lastUsed: now),
            ],
            extraPhrases: ["Ghostty", "Safari", "Xcode", "Slack"],
            counter: FakeCounter(),
            config: BudgetConfig(
                hardCap: 500,
                tokenBudget: 200,
                substitutionTopN: 40,
                recencyHalfLifeDays: 14,
                promoteMin: 2,
                appNameCap: appNameCap),
            now: now)
        XCTAssertEqual(prompt, "Alpha, Beta, Gamma, Ghostty, Safari")
    }

    func testUnpromotedEntriesAreFiltered() {
        let now = Date()
        let prompt = BiasPromptBuilder().build(
            promotedEntries: [
                entry(term: "Kubernetes", lastUsed: now),
                entry(term: "Zephyr", lastUsed: now, promoted: false),
            ],
            extraPhrases: [],
            counter: FakeCounter(),
            now: now)
        XCTAssertEqual(prompt, "Kubernetes")
        XCTAssertFalse((prompt ?? "").contains("Zephyr"))
    }

    private func entry(term: String, lastUsed: Date, promoted: Bool = true) -> DictionaryEntry {
        DictionaryEntry(
            id: term,
            correctTerm: term,
            mishearings: [],
            occurrenceCount: 1,
            promoted: promoted,
            source: .explicit,
            createdAt: lastUsed,
            lastUsedAt: lastUsed)
    }
}
