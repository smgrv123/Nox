import XCTest

@testable import Personalization

final class BudgetConfigTests: XCTestCase {

    func testDefaultValues() {
        let config = BudgetConfig.default
        XCTAssertEqual(config.hardCap, 500)
        XCTAssertEqual(config.tokenBudget, 200)
        XCTAssertEqual(config.substitutionTopN, 40)
        XCTAssertEqual(config.recencyHalfLifeDays, 14)
        XCTAssertEqual(config.promoteMin, 2)
        XCTAssertEqual(config.appNameCap, 50)
        XCTAssertEqual(config.whisperPromptCap, 224)
    }
}
