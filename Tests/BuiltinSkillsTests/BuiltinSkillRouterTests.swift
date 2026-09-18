import SkillManifest
import XCTest

@testable import BuiltinSkills

final class BuiltinSkillRouterTests: XCTestCase {

    func testCorrectThatSucceedsWithDictionary() async throws {
        let spy = RecordingSpy()
        _ = try await makeRouter(dictionary: spy).execute(
            skillID: "correct_that",
            parameters: objectParams([
                "mishearing": .string("alpha"),
                "correct_term": .string("beta"),
            ]))
        XCTAssertEqual(spy.records.count, 1)
        XCTAssertEqual(spy.records.first?.mishearing, "alpha")
        XCTAssertEqual(spy.records.first?.correctTerm, "beta")
    }
}
