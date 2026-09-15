import XCTest

@testable import Personalization

final class MRUEvictionTests: XCTestCase {

    func testEvictsOldestAutoBeforeExplicit() {
        // explicit-old is globally oldest; auto-old is still newer than it.
        // A lastUsedAt-only evictor would drop explicit-old and keep auto-old.
        let oldExplicit = entry(id: "explicit-old", source: .explicit, lastUsed: date(2019))
        let newAuto = entry(id: "auto-new", source: .auto, lastUsed: date(2025))
        let olderAuto = entry(id: "auto-old", source: .auto, lastUsed: date(2022))

        let kept = MRUEviction.evict([oldExplicit, newAuto, olderAuto], cap: 2)

        XCTAssertEqual(Set(kept.map(\.id)), ["explicit-old", "auto-new"])
    }

    func testCapsAtHardCap() {
        let cap = 3
        let entries = (0..<5).map { index in
            entry(id: "e\(index)", source: .explicit, lastUsed: date(2020 + index))
        }

        let kept = MRUEviction.evict(entries, cap: cap)

        XCTAssertEqual(kept.count, cap)
        XCTAssertEqual(kept.map(\.id), ["e2", "e3", "e4"])
    }

    private func entry(id: String, source: DictionaryEntry.Source, lastUsed: Date) -> DictionaryEntry {
        DictionaryEntry(
            id: id,
            correctTerm: id,
            mishearings: [],
            occurrenceCount: 1,
            promoted: source == .explicit,
            source: source,
            createdAt: lastUsed,
            lastUsedAt: lastUsed)
    }

    private func date(_ year: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
    }
}
