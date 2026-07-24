import XCTest

@testable import Persistence

/// Plain-text, human-readable, timestamped app log (User Story 35; docs/05-lld.md
/// §2.6 / §9 — `logs/app.log`). The clock is injected so timestamps are exact and
/// the assertions are deterministic; no telemetry, no network — a local file only.
final class AppLogTests: XCTestCase {

    private var fileURL: URL!
    private let fileManager = FileManager.default
    private let fixedDate = Date(timeIntervalSince1970: 1_753_347_124.221)  // 2025-07-24T09:12:04.221Z

    override func setUpWithError() throws {
        let directory = fileManager.temporaryDirectory
            .appending(path: "aide-applog-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "app.log")
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func makeLog() -> AppLog {
        AppLog(fileURL: fileURL, now: { self.fixedDate })
    }

    private func contents() throws -> String {
        try XCTUnwrap(String(bytes: try Data(contentsOf: fileURL), encoding: .utf8))
    }

    func testLogCreatesTheFileWhenMissing() throws {
        XCTAssertFalse(fileManager.fileExists(atPath: fileURL.path))
        makeLog().log("Aide launched")
        XCTAssertTrue(fileManager.fileExists(atPath: fileURL.path))
    }

    func testEntryIsTimestampedAndHumanReadable() throws {
        makeLog().log("Aide launched")
        let expected = "\(Timestamp.string(from: fixedDate)) [INFO] Aide launched\n"
        XCTAssertEqual(try contents(), expected)
    }

    func testTimestampRoundTripsAsISO8601() throws {
        makeLog().log("Aide launched")
        let stamp = try XCTUnwrap(try contents().split(separator: " ").first).description
        XCTAssertEqual(Timestamp.date(from: stamp), fixedDate)
    }

    func testLevelIsRenderedInTheLine() throws {
        makeLog().log("storage tree unavailable", level: .error)
        XCTAssertTrue(try contents().contains("[ERROR] storage tree unavailable"))
    }

    func testEntriesAppendInOrder() throws {
        let log = makeLog()
        log.log("first")
        log.log("second", level: .warning)
        let lines = try contents().split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("[INFO] first"))
        XCTAssertTrue(lines[1].hasSuffix("[WARNING] second"))
    }
}
