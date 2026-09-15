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
            insertion: .paste,
            destinationBundleID: "com.microsoft.VSCode",
            audioMs: 1200,
            sttMs: 340,
            modelLoadMs: 0,
            cleanupMs: 5330,
            insertMs: 12,
            totalMs: 5680)
        let data = try JSONEncoder().encode(entry)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["mode"] as? String, "dictation")
        XCTAssertEqual(json["transcript"] as? String, "hello world")
        XCTAssertEqual(json["cleaned"] as? String, "Hello world.")
        XCTAssertEqual(json["insertion"] as? String, "paste")
        XCTAssertEqual(json["cleanup_ran"] as? Bool, true)
        XCTAssertEqual(json["destination_bundle_id"] as? String, "com.microsoft.VSCode")
        XCTAssertEqual(json["audio_ms"] as? Int, 1200)
        XCTAssertEqual(json["stt_ms"] as? Int, 340)
        XCTAssertEqual(json["model_load_ms"] as? Int, 0)
        XCTAssertEqual(json["cleanup_ms"] as? Int, 5330)
        XCTAssertEqual(json["insert_ms"] as? Int, 12)
        XCTAssertEqual(json["total_ms"] as? Int, 5680)
        XCTAssertNil(json["cleanupRan"])
        XCTAssertNil(json["destinationBundleID"])
        XCTAssertNil(json["audioMs"])
        XCTAssertNil(json["sttMs"])
        XCTAssertNil(json["modelLoadMs"])
        XCTAssertNil(json["cleanupMs"])
        XCTAssertNil(json["insertMs"])
        XCTAssertNil(json["totalMs"])
    }

    /// Older lines in `history/commands-*.jsonl` predate the P5a-latency fields —
    /// every timing field must decode as `nil`, not throw, so the reader never
    /// chokes on history written before this change.
    func testDecodeIsTolerantOfMissingTimingFields() throws {
        let legacyLine = """
            {"ts":1753347124,"mode":"dictation","transcript":"hello world",\
            "cleanup_ran":false,"insertion":"ax"}
            """
        let entry = try JSONDecoder().decode(
            DictationHistoryEntry.self, from: Data(legacyLine.utf8))

        XCTAssertEqual(entry.transcript, "hello world")
        XCTAssertNil(entry.audioMs)
        XCTAssertNil(entry.sttMs)
        XCTAssertNil(entry.modelLoadMs)
        XCTAssertNil(entry.cleanupMs)
        XCTAssertNil(entry.insertMs)
        XCTAssertNil(entry.totalMs)
    }
}
