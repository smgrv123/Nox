import XCTest

@testable import WhisperSTTEngine

/// Headless clamp for C `whisper_token_count` results. No whisper context or
/// model — these always run in `swift test`.
final class WhisperTokenCounterClampTests: XCTestCase {

    func testZeroPassesThrough() {
        XCTAssertEqual(WhisperTokenCounter.clampedTokenCount(0), 0)
    }

    func testPositivePassesThrough() {
        XCTAssertEqual(WhisperTokenCounter.clampedTokenCount(17), 17)
    }

    func testNegativeExceedsAnyBudget() {
        XCTAssertEqual(WhisperTokenCounter.clampedTokenCount(-1), .max)
        XCTAssertGreaterThan(WhisperTokenCounter.clampedTokenCount(-1), 0)
    }
}
