import Foundation
import LLMRuntime
import SkillManifest
import XCTest

@testable import CommandRouter

final class RouterContractParserTests: XCTestCase {

    func testParsesValidContractV2JSON() throws {
        let raw = """
            {"intent":"open Safari","skill_id":"open_application","parameters":{"app_name":"Safari"}}
            """

        let decision = try RouterContractParser.parse(raw)

        XCTAssertEqual(decision.intent, "open Safari")
        XCTAssertEqual(decision.skillID, "open_application")
        XCTAssertEqual(decision.parameters, .object(["app_name": .string("Safari")]))
    }

    func testParsesNullSkillIDAsNil() throws {
        let raw = """
            {"intent":"nothing matches","skill_id":null,"parameters":{}}
            """

        let decision = try RouterContractParser.parse(raw)

        XCTAssertEqual(decision.intent, "nothing matches")
        XCTAssertNil(decision.skillID)
        XCTAssertEqual(decision.parameters, .object([:]))
    }

    func testRejectsMalformedNonJSON() {
        XCTAssertThrowsError(try RouterContractParser.parse("not json at all")) { error in
            XCTAssertEqual(error as? RouterContractError, .malformedJSON)
        }
    }

    func testRejectsJSONArray() {
        XCTAssertThrowsError(try RouterContractParser.parse("[1,2,3]")) { error in
            XCTAssertEqual(error as? RouterContractError, .malformedJSON)
        }
    }

    func testRejectsMissingIntent() {
        let raw = """
            {"skill_id":"open_application","parameters":{}}
            """
        XCTAssertThrowsError(try RouterContractParser.parse(raw)) { error in
            XCTAssertEqual(error as? RouterContractError, .missingKey("intent"))
        }
    }

    func testRejectsMissingSkillID() {
        let raw = """
            {"intent":"open Safari","parameters":{}}
            """
        XCTAssertThrowsError(try RouterContractParser.parse(raw)) { error in
            XCTAssertEqual(error as? RouterContractError, .missingKey("skill_id"))
        }
    }

    func testRejectsMissingParameters() {
        let raw = """
            {"intent":"open Safari","skill_id":"open_application"}
            """
        XCTAssertThrowsError(try RouterContractParser.parse(raw)) { error in
            XCTAssertEqual(error as? RouterContractError, .missingKey("parameters"))
        }
    }

    func testRejectsWrongIntentType() {
        let raw = """
            {"intent":1,"skill_id":"open_application","parameters":{}}
            """
        XCTAssertThrowsError(try RouterContractParser.parse(raw)) { error in
            XCTAssertEqual(error as? RouterContractError, .wrongType(key: "intent"))
        }
    }

    func testRejectsWrongSkillIDType() {
        let raw = """
            {"intent":"open Safari","skill_id":42,"parameters":{}}
            """
        XCTAssertThrowsError(try RouterContractParser.parse(raw)) { error in
            XCTAssertEqual(error as? RouterContractError, .wrongType(key: "skill_id"))
        }
    }

    func testRejectsWrongParametersType() {
        let raw = """
            {"intent":"open Safari","skill_id":"open_application","parameters":[]}
            """
        XCTAssertThrowsError(try RouterContractParser.parse(raw)) { error in
            XCTAssertEqual(error as? RouterContractError, .wrongType(key: "parameters"))
        }
    }

    func testRejectsEmptyIntent() {
        let raw = """
            {"intent":"","skill_id":"open_application","parameters":{}}
            """
        XCTAssertThrowsError(try RouterContractParser.parse(raw)) { error in
            XCTAssertEqual(error as? RouterContractError, .emptyIntent)
        }
    }

    func testRejectsIntentOverMaxLength() {
        let intent = String(repeating: "a", count: 201)
        let raw = """
            {"intent":"\(intent)","skill_id":"open_application","parameters":{}}
            """
        XCTAssertThrowsError(try RouterContractParser.parse(raw)) { error in
            XCTAssertEqual(error as? RouterContractError, .intentTooLong)
        }
    }

    func testAcceptsIntentAtMaxLength() throws {
        let intent = String(repeating: "a", count: 200)
        let raw = """
            {"intent":"\(intent)","skill_id":"open_application","parameters":{}}
            """

        let decision = try RouterContractParser.parse(raw)

        XCTAssertEqual(decision.intent, intent)
        XCTAssertEqual(decision.skillID, "open_application")
        XCTAssertEqual(decision.parameters, .object([:]))
    }

    func testRejectsExtraKeys() {
        let raw = """
            {"intent":"open Safari","skill_id":"open_application","parameters":{},"confidence":0.9}
            """
        XCTAssertThrowsError(try RouterContractParser.parse(raw)) { error in
            XCTAssertEqual(error as? RouterContractError, .unexpectedKey("confidence"))
        }
    }

    func testParsesRouterCompletionRaw() throws {
        let completion = RouterCompletion(
            raw: """
                {"intent":"set a timer","skill_id":"set_timer","parameters":{"duration_seconds":300}}
                """,
            tokenLogprobs: [])
        let decision = try RouterContractParser.parse(completion)
        XCTAssertEqual(decision.intent, "set a timer")
        XCTAssertEqual(decision.skillID, "set_timer")
        XCTAssertEqual(decision.parameters, .object(["duration_seconds": .int(300)]))
    }
}
