import XCTest

@testable import BuiltinSkills

/// Q&A stubs: P6 wires the real skills; these keep the router executable today.
final class QASkillTests: XCTestCase {

    func testGeneralQAStubReturnsNotYetAvailable() async throws {
        let result = try await makeRouter().execute(
            skillID: "general_qa",
            parameters: objectParams(["question": .string("who wrote Hamlet")])
        )
        XCTAssertEqual(result.summary, "General Q&A is not yet available")
    }

    func testScreenQAStubReturnsNotYetAvailable() async throws {
        let result = try await makeRouter().execute(
            skillID: "screen_qa",
            parameters: objectParams(["question": .string("what's on my screen")])
        )
        XCTAssertEqual(result.summary, "Screen Q&A is not yet available")
    }
}
