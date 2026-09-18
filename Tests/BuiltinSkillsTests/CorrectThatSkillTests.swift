import AideCore
import SkillManifest
import XCTest

@testable import BuiltinSkills

final class CorrectThatSkillTests: XCTestCase {

    func testRecordsPair() async throws {
        let spy = RecordingSpy()
        let result = try await CorrectThatSkill.run(
            parameters: objectParams([
                "mishearing": .string("cooper nettie's"),
                "correct_term": .string("Kubernetes"),
            ]),
            dictionary: spy)
        XCTAssertEqual(spy.records.count, 1)
        XCTAssertEqual(spy.records.first?.mishearing, "cooper nettie's")
        XCTAssertEqual(spy.records.first?.correctTerm, "Kubernetes")
        XCTAssertEqual(
            result.summary,
            "Remembered “Kubernetes” (heard as “cooper nettie's”).")
    }

    func testMissingParameterFails() async {
        let spy = RecordingSpy()
        await assertMissing(
            parameters: objectParams(["correct_term": .string("Kubernetes")]),
            dictionary: spy,
            key: "mishearing")
        await assertMissing(
            parameters: objectParams(["mishearing": .string("alpha")]),
            dictionary: spy,
            key: "correct_term")
        XCTAssertTrue(spy.records.isEmpty)
    }

    private func assertMissing(
        parameters: JSONValue,
        dictionary: RecordingSpy,
        key: String
    ) async {
        do {
            _ = try await CorrectThatSkill.run(parameters: parameters, dictionary: dictionary)
            XCTFail("expected missing parameter \(key)")
        } catch SkillExecutionError.missingParameter(let missing) {
            XCTAssertEqual(missing, key)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
