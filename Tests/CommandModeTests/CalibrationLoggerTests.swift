import AideCore
import Foundation
import XCTest

@testable import CommandMode

/// Append-only JSONL calibration log (plan Phase 7). Injected file URL so the suite
/// never touches the real Application Support tree.
final class CalibrationLoggerTests: XCTestCase {

    private var fileURL: URL!
    private let fileManager = FileManager.default
    private let when = Date(timeIntervalSince1970: 1_753_347_124.221)

    override func setUpWithError() throws {
        let directory = fileManager.temporaryDirectory
            .appending(path: "aide-calibration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "calibration.jsonl")
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testAppendsRecordToInjectedTempFile() throws {
        let logger = CalibrationLogger(fileURL: fileURL)
        try logger.append(sample(scannerVerdict: "clean", actionTaken: "executed"))

        let text = try rawText()
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1, "one JSON object per line")
        let line = try XCTUnwrap(text.split(separator: "\n").first)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
    }

    func testAppendedRecordIncludesCalibrationFields() throws {
        let logger = CalibrationLogger(fileURL: fileURL)
        try logger.append(
            sample(
                whisperAvgLogprob: -0.30,
                routingLogprobMean: -0.08,
                chosenSkillID: "open_application",
                riskTier: .low,
                scannerVerdict: "clean",
                actionTaken: "executed"
            )
        )

        let json = try decodedLine()
        let avg = try XCTUnwrap(json["whisper_avg_logprob"] as? Double)
        let mean = try XCTUnwrap(json["routing_logprob_mean"] as? Double)
        XCTAssertEqual(avg, -0.30, accuracy: 0.0001)
        XCTAssertEqual(mean, -0.08, accuracy: 0.0001)
        XCTAssertEqual(json["chosen_skill_id"] as? String, "open_application")
        XCTAssertEqual(json["risk_tier"] as? String, "low")
        XCTAssertEqual(json["scanner_verdict"] as? String, "clean")
        XCTAssertEqual(json["action_taken"] as? String, "executed")
        XCTAssertTrue(json["user_outcome"] is NSNull)
    }

    func testHardBlockLogsHardBlockScannerVerdict() throws {
        let logger = CalibrationLogger(fileURL: fileURL)
        try logger.append(
            sample(
                scannerVerdict: "hard_block",
                actionTaken: "hard_block"
            )
        )

        let json = try decodedLine()
        XCTAssertEqual(json["scanner_verdict"] as? String, "hard_block")
        XCTAssertEqual(json["action_taken"] as? String, "hard_block")
    }

    // MARK: - Fixtures

    private func sample(
        whisperAvgLogprob: Float = -0.21,
        routingLogprobMean: Float = -0.08,
        chosenSkillID: String? = "open_application",
        riskTier: RiskTier? = .low,
        scannerVerdict: String? = "clean",
        actionTaken: String? = "executed"
    ) -> CalibrationRecord {
        CalibrationRecord(
            ts: when,
            whisperAvgLogprob: whisperAvgLogprob,
            whisperMinSegmentLogprob: -0.44,
            sttPregate: "pass",
            chosenSkillID: chosenSkillID,
            idSelectingTokenCount: 1,
            routingLogprobSum: routingLogprobMean,
            routingLogprobMean: routingLogprobMean,
            paramValidation: "pass",
            riskTier: riskTier,
            scannerVerdict: scannerVerdict,
            actionTaken: actionTaken,
            userOutcome: nil,
            latencyMs: 12
        )
    }

    private func rawText() throws -> String {
        try XCTUnwrap(String(bytes: try Data(contentsOf: fileURL), encoding: .utf8))
    }

    private func decodedLine() throws -> [String: Any] {
        let line = try XCTUnwrap(rawText().split(separator: "\n").first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}
