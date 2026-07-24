import XCTest

@testable import Persistence

/// Stand-in for P4's command-history record: it owns its exact JSON keys, the way a
/// real entry declares `skill_id` (docs/05-lld.md §2.6). File-scoped so `CodingKeys`
/// isn't nested two levels deep.
private struct HistoryEntry: Codable, Equatable {
    let ts: Date
    let transcript: String
    let skillID: String

    enum CodingKeys: String, CodingKey {
        case ts
        case transcript
        case skillID = "skill_id"
    }
}

/// Append-only JSONL history log (User Story 33/35; docs/05-lld.md §2.6).
///
/// One JSON object per line, greppable and tail-able. The writer is generic over
/// `Codable` so P4's command-history entry plugs in unchanged; here a small local
/// entry stands in. Entry-defined keys and ISO-8601 timestamps match the LLD wire
/// format so later phases inherit it for free.
final class HistoryLogTests: XCTestCase {

    private var fileURL: URL!
    private let fileManager = FileManager.default
    // A whole-millisecond instant so the ISO-8601 round-trip is exact.
    private let when = Date(timeIntervalSince1970: 1_753_347_124.221)

    override func setUpWithError() throws {
        let directory = fileManager.temporaryDirectory
            .appending(path: "aide-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "commands-2025-07-24.jsonl")
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func makeLog() -> HistoryLog { HistoryLog(fileURL: fileURL) }

    private func rawText() throws -> String {
        try XCTUnwrap(String(bytes: try Data(contentsOf: fileURL), encoding: .utf8))
    }

    func testAppendThenReadBackRoundTrips() throws {
        let entry = HistoryEntry(ts: when, transcript: "open safari", skillID: "open_application")
        let log = makeLog()
        try log.append(entry)
        XCTAssertEqual(try log.readAll(HistoryEntry.self), [entry])
    }

    func testEachAppendIsExactlyOneLine() throws {
        let log = makeLog()
        try log.append(HistoryEntry(ts: when, transcript: "one", skillID: "a"))
        try log.append(HistoryEntry(ts: when, transcript: "two", skillID: "b"))

        let text = try rawText()
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 2)
        for line in text.split(separator: "\n") {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(line.utf8)),
                "line is not standalone JSON: \(line)")
        }
    }

    func testAppendsPreserveOrderAcrossCalls() throws {
        let first = HistoryEntry(ts: when, transcript: "first", skillID: "a")
        let second = HistoryEntry(ts: when, transcript: "second", skillID: "b")
        let log = makeLog()
        try log.append(first)
        try log.append(second)
        XCTAssertEqual(try log.readAll(HistoryEntry.self), [first, second])
    }

    func testEntryKeysArePreservedAndTimestampIsISO8601() throws {
        try makeLog().append(HistoryEntry(ts: when, transcript: "hi", skillID: "open_application"))
        let text = try rawText()
        XCTAssertTrue(text.contains("\"skill_id\""), "entry-defined keys should survive: \(text)")
        XCTAssertFalse(text.contains("\"skillID\""))
        XCTAssertTrue(text.contains(Timestamp.string(from: when)))
    }

    func testReadingAMissingFileReturnsEmpty() throws {
        XCTAssertEqual(try makeLog().readAll(HistoryEntry.self), [])
    }
}
