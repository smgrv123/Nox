import Foundation
import XCTest

@testable import Dictation

final class DictationHistoryEntryTests: XCTestCase {

    func testJSONKeysSnakeCase() throws {
        let entry = DictationHistoryEntry(
            ts: Date(timeIntervalSince1970: 1_753_347_124),
            transcript: "hello world",
            cleaned: "Hello world.",
            cleanupRan: true,
            insertion: "paste",
            destinationBundleID: "com.microsoft.VSCode")
        let data = try JSONEncoder().encode(entry)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["mode"] as? String, "dictation")
        XCTAssertEqual(json["transcript"] as? String, "hello world")
        XCTAssertEqual(json["cleaned"] as? String, "Hello world.")
        XCTAssertEqual(json["insertion"] as? String, "paste")
        XCTAssertEqual(json["cleanup_ran"] as? Bool, true)
        XCTAssertEqual(json["destination_bundle_id"] as? String, "com.microsoft.VSCode")
        XCTAssertNil(json["cleanupRan"])
        XCTAssertNil(json["destinationBundleID"])
    }
}
