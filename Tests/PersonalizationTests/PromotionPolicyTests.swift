import XCTest

@testable import Personalization

final class PromotionPolicyTests: XCTestCase {

    func testExplicitIsImmediate() {
        XCTAssertTrue(
            PromotionPolicy.isPromoted(
                source: .explicit,
                occurrenceCount: 1,
                promoteMin: 99))
    }

    func testAutoBelowMinNotPromoted() {
        XCTAssertFalse(
            PromotionPolicy.isPromoted(
                source: .auto,
                occurrenceCount: 1,
                promoteMin: 2))
    }

    func testAutoAtMinIsPromoted() {
        XCTAssertTrue(
            PromotionPolicy.isPromoted(
                source: .auto,
                occurrenceCount: 2,
                promoteMin: 2))
    }
}
