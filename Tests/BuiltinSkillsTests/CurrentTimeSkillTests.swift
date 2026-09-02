import Foundation
import SkillManifest
import XCTest

@testable import BuiltinSkills

final class CurrentTimeSkillTests: XCTestCase {

    func testReturnsUTCTime() async throws {
        let summary = try await timeSummary(timezone: "UTC")
        XCTAssertTrue(summary.contains("12:00:00"), "expected noon clock in \(summary)")
        XCTAssertTrue(
            summary.contains("Z") || summary.contains("+00:00") || summary.contains("UTC")
                || summary.contains("GMT"),
            "expected UTC/GMT marker in \(summary)"
        )
    }

    func testReturnsTokyoTime() async throws {
        let summary = try await timeSummary(timezone: "Asia/Tokyo")
        XCTAssertTrue(summary.contains("21:00:00"), "expected 21:00 JST in \(summary)")
        XCTAssertTrue(
            summary.contains("+09:00") || summary.contains("JST") || summary.contains("GMT+9"),
            "expected Tokyo offset/abbreviation in \(summary)"
        )
    }

    func testReturnsNewYorkTime() async throws {
        let summary = try await timeSummary(timezone: "America/New_York")
        XCTAssertTrue(summary.contains("08:00:00"), "expected 08:00 EDT in \(summary)")
        XCTAssertTrue(
            summary.contains("-04:00") || summary.contains("EDT") || summary.contains("GMT-4"),
            "expected New York offset/abbreviation in \(summary)"
        )
    }

    func testReturnsLocalTimeWhenTimezoneOmitted() async throws {
        let summary = try await timeSummary(timezone: nil)
        let expected = localISOClock(FrozenClock.date)
        XCTAssertTrue(
            summary.contains(expected),
            "expected local clock \(expected) in \(summary)"
        )
    }

    private func timeSummary(timezone: String?) async throws -> String {
        var fields: [String: JSONValue] = [:]
        if let timezone {
            fields["timezone"] = .string(timezone)
        }
        let result = try await frozenRouter().execute(
            skillID: "current_time",
            parameters: objectParams(fields)
        )
        return result.summary
    }

    private func localISOClock(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
