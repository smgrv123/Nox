import XCTest

@testable import Dictation

final class CleanupResponseSanitizerTests: XCTestCase {

    func testStripsQuotedModelPreamble() {
        let raw = "\"Here is the cleaned text: Hello there.\""
        XCTAssertEqual(CleanupResponseSanitizer.sanitize(raw), "Hello there.")
    }

    func testLeavesCleanTextAlone() {
        let clean = "The meeting is at three."
        XCTAssertEqual(CleanupResponseSanitizer.sanitize(clean), clean)
    }
}
