import AideCore
import Foundation
import Persistence
import XCTest

@testable import CommandMode

/// JSONL wire shape for one calibration line (docs/05-lld.md §4.2). Keys are asserted
/// present — including `user_outcome: null` when no feedback has arrived yet.
final class CalibrationRecordTests: XCTestCase {

    /// Whole-millisecond instant so the ISO-8601 round-trip is exact.
    private let when = Date(timeIntervalSince1970: 1_753_347_124.221)

    private var sample: CalibrationRecord {
        CalibrationRecord(
            ts: when,
            whisperAvgLogprob: -0.21,
            whisperMinSegmentLogprob: -0.44,
            sttPregate: "pass",
            chosenSkillID: "open_application",
            idSelectingTokenCount: 3,
            routingLogprobSum: -0.24,
            routingLogprobMean: -0.08,
            paramValidation: "pass",
            riskTier: .low,
            scannerVerdict: "clean",
            actionTaken: "executed",
            userOutcome: nil,
            latencyMs: 870
        )
    }

    func testEncodesExpectedJSONLKeysIncludingNullUserOutcome() throws {
        let data = try encoder.encode(sample)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set(json.keys)
        XCTAssertEqual(keys, expectedKeys, "LLD §4.2 keys must all be present, including nulls")
        XCTAssertEqual(json["mode"] as? String, "command")
        XCTAssertTrue(json["user_outcome"] is NSNull, "pending outcome is JSON null, not omitted")
        XCTAssertEqual(json["action_taken"] as? String, "executed")
        XCTAssertEqual(json["chosen_skill_id"] as? String, "open_application")
        XCTAssertEqual(json["scanner_verdict"] as? String, "clean")
        XCTAssertEqual(json["risk_tier"] as? String, "low")
        XCTAssertEqual(json["ts"] as? String, Timestamp.string(from: when))
    }

    func testDecodeRoundTrips() throws {
        let data = try encoder.encode(sample)
        let decoded = try decoder.decode(CalibrationRecord.self, from: data)
        XCTAssertEqual(decoded.ts, sample.ts)
        XCTAssertEqual(decoded.mode, sample.mode)
        XCTAssertEqual(decoded.whisperAvgLogprob, sample.whisperAvgLogprob)
        XCTAssertEqual(decoded.whisperMinSegmentLogprob, sample.whisperMinSegmentLogprob)
        XCTAssertEqual(decoded.sttPregate, sample.sttPregate)
        XCTAssertEqual(decoded.chosenSkillID, sample.chosenSkillID)
        XCTAssertEqual(decoded.idSelectingTokenCount, sample.idSelectingTokenCount)
        XCTAssertEqual(decoded.routingLogprobSum, sample.routingLogprobSum)
        XCTAssertEqual(decoded.routingLogprobMean, sample.routingLogprobMean)
        XCTAssertEqual(decoded.paramValidation, sample.paramValidation)
        XCTAssertEqual(decoded.riskTier, sample.riskTier)
        XCTAssertEqual(decoded.scannerVerdict, sample.scannerVerdict)
        XCTAssertEqual(decoded.actionTaken, sample.actionTaken)
        XCTAssertNil(decoded.userOutcome)
        XCTAssertEqual(decoded.latencyMs, sample.latencyMs)
    }

    // MARK: - Codec

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Timestamp.string(from: date))
        }
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = Timestamp.date(from: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO-8601 timestamp: \(raw)"))
            }
            return date
        }
        return decoder
    }

    private var expectedKeys: Set<String> {
        [
            "ts",
            "mode",
            "whisper_avg_logprob",
            "whisper_min_segment_logprob",
            "stt_pregate",
            "chosen_skill_id",
            "id_selecting_token_count",
            "routing_logprob_sum",
            "routing_logprob_mean",
            "param_validation",
            "risk_tier",
            "scanner_verdict",
            "action_taken",
            "user_outcome",
            "latency_ms",
        ]
    }
}
