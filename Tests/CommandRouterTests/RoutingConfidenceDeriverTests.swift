import Foundation
import LLMRuntime
import XCTest

@testable import CommandRouter

final class RoutingConfidenceDeriverTests: XCTestCase {

    /// Compact Contract v2 JSON — GBNF-shaped, no extra whitespace around `skill_id`.
    private let openAppRaw =
        #"{"intent":"open Safari","skill_id":"open_application","parameters":{"app_name":"Safari"}}"#

    func testCollectsOverlappingTokensAndComputesSumAndMean() throws {
        let valueRange = try utf8Range(of: #""open_application""#, in: openAppRaw)
        let overlapping = TokenLogprob(
            token: #""open_application""#, logprob: -0.24, byteRange: valueRange)
        let before = TokenLogprob(
            token: "intent", logprob: -0.01, byteRange: 2..<8)
        let after = TokenLogprob(
            token: "parameters", logprob: -0.99, byteRange: (valueRange.upperBound + 2)..<(valueRange.upperBound + 12))

        let completion = RouterCompletion(
            raw: openAppRaw, tokenLogprobs: [before, overlapping, after])

        let confidence = try RoutingConfidenceDeriver.derive(from: completion)

        XCTAssertEqual(confidence.idSelectingTokenCount, 1)
        XCTAssertEqual(confidence.logprobSum, -0.24)
        XCTAssertEqual(confidence.logprobMean, -0.24)
    }

    func testLocatesSkillIDValueByteRange() throws {
        let expected = try utf8Range(of: #""open_application""#, in: openAppRaw)
        let located = try RoutingConfidenceDeriver.skillIDValueByteRange(in: openAppRaw)
        XCTAssertEqual(located, expected)
        let literal = String(bytes: Array(openAppRaw.utf8)[located], encoding: .utf8)
        XCTAssertEqual(literal, #""open_application""#)
    }

    func testHandlesMultiTokenSkillID() throws {
        let valueRange = try utf8Range(of: #""open_application""#, in: openAppRaw)
        let first = TokenLogprob(
            token: #""open"#, logprob: -0.10, byteRange: valueRange.lowerBound..<(valueRange.lowerBound + 5))
        let second = TokenLogprob(
            token: "_application\"", logprob: -0.20, byteRange: (valueRange.lowerBound + 5)..<valueRange.upperBound)
        let completion = RouterCompletion(raw: openAppRaw, tokenLogprobs: [first, second])

        let confidence = try RoutingConfidenceDeriver.derive(from: completion)

        XCTAssertEqual(confidence.idSelectingTokenCount, 2)
        XCTAssertEqual(confidence.logprobSum, -0.30)
        XCTAssertEqual(confidence.logprobMean, -0.15)
    }

    func testHandlesNullSkillIDLiteral() throws {
        let raw = #"{"intent":"nothing matches","skill_id":null,"parameters":{}}"#
        let valueRange = try utf8Range(of: "null", in: raw)
        let nullToken = TokenLogprob(token: "null", logprob: -0.40, byteRange: valueRange)
        let other = TokenLogprob(token: "intent", logprob: -0.01, byteRange: 2..<8)
        let completion = RouterCompletion(raw: raw, tokenLogprobs: [other, nullToken])

        let located = try RoutingConfidenceDeriver.skillIDValueByteRange(in: raw)
        XCTAssertEqual(located, valueRange)

        let confidence = try RoutingConfidenceDeriver.derive(from: completion)
        XCTAssertEqual(confidence.idSelectingTokenCount, 1)
        XCTAssertEqual(confidence.logprobSum, -0.40)
        XCTAssertEqual(confidence.logprobMean, -0.40)
    }

    func testEmptyOverlappingSetIsFailClosed() {
        let completion = RouterCompletion(raw: openAppRaw, tokenLogprobs: [])
        XCTAssertThrowsError(try RoutingConfidenceDeriver.derive(from: completion)) { error in
            XCTAssertEqual(error as? RoutingConfidenceError, .noIdSelectingTokens)
        }
    }

    func testNonOverlappingTokensAreFailClosed() {
        let miss = TokenLogprob(token: "intent", logprob: -0.01, byteRange: 2..<8)
        let completion = RouterCompletion(raw: openAppRaw, tokenLogprobs: [miss])
        XCTAssertThrowsError(try RoutingConfidenceDeriver.derive(from: completion)) { error in
            XCTAssertEqual(error as? RoutingConfidenceError, .noIdSelectingTokens)
        }
    }

    func testWhitespaceAfterColonIsSkipped() throws {
        let raw = #"{"intent":"x","skill_id": "open_application","parameters":{}}"#
        let expected = try utf8Range(of: #""open_application""#, in: raw)
        let located = try RoutingConfidenceDeriver.skillIDValueByteRange(in: raw)
        XCTAssertEqual(located, expected)
    }

    func testMissingSkillIDKeyIsAnError() {
        XCTAssertThrowsError(try RoutingConfidenceDeriver.skillIDValueByteRange(in: "{}")) { error in
            XCTAssertEqual(error as? RoutingConfidenceError, .skillIDValueNotFound)
        }
    }
}
