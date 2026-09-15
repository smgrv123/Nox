import XCTest

@testable import Personalization

final class RecencyWeightTests: XCTestCase {

    func testHalfLifeHalvesScore() {
        let now = Date()
        let halfLifeDays = 14.0
        let halfLifeAgo = now.addingTimeInterval(-halfLifeDays * 86_400)

        XCTAssertEqual(
            RecencyWeight.weight(lastUsedAt: halfLifeAgo, now: now, halfLifeDays: halfLifeDays),
            0.5,
            accuracy: 1e-12)
        XCTAssertEqual(
            RecencyWeight.weight(lastUsedAt: now, now: now, halfLifeDays: halfLifeDays),
            1.0,
            accuracy: 1e-12)
    }
}
