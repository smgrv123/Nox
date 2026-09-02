import SkillManifest
import XCTest

@testable import BuiltinSkills

final class CalculateSkillTests: XCTestCase {

    func testEvaluatesPercentOf() async throws {
        let summary = try await evaluate("15% of 230")
        XCTAssertTrue(summary.contains("34.5"), "expected 34.5 in \(summary)")
    }

    func testEvaluatesBasicArithmetic() async throws {
        try await assertContains("2 + 3", "5")
        try await assertContains("10 - 4", "6")
        try await assertContains("6 * 7", "42")
        try await assertContains("15 / 3", "5")
        try await assertContains("10 % 3", "1")
        try await assertContains("(2 + 3) * 4", "20")
    }

    func testMalformedExpressionReturnsHumanReadableError() async throws {
        let summary = try await evaluate("not a formula")
        let lowered = summary.lowercased()
        XCTAssertTrue(
            lowered.contains("couldn't") || lowered.contains("malformed")
                || lowered.contains("invalid") || lowered.contains("couldn't evaluate"),
            "expected a human-readable error, got \(summary)"
        )
        let trailing = try await evaluate("2 +")
        XCTAssertFalse(trailing.summaryLooksLikeCrash)
    }

    private func evaluate(_ expression: String) async throws -> String {
        let result = try await makeRouter().execute(
            skillID: "calculate",
            parameters: objectParams(["expression": .string(expression)])
        )
        return result.summary
    }

    private func assertContains(_ expression: String, _ needle: String) async throws {
        let summary = try await evaluate(expression)
        XCTAssertTrue(summary.contains(needle), "expected \(needle) in \(summary) for \(expression)")
    }
}

extension String {
    fileprivate var summaryLooksLikeCrash: Bool {
        lowercased().contains("fatal") || lowercased().contains("precondition")
    }
}
