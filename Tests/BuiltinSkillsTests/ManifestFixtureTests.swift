import Foundation
import SkillManifest
import XCTest

final class ManifestFixtureTests: XCTestCase {

    func testEachSkillHasACorrespondingValidManifestFixture() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let fixtureNames = [
            "open_application",
            "quit_application",
            "set_timer",
            "media_control",
            "take_screenshot",
            "current_time",
            "calculate",
            "general_qa",
            "screen_qa",
            "unit_conversion",
        ]

        for name in fixtureNames {
            let url = Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures")
            XCTAssertNotNil(url, "missing fixture \(name).json")
            guard let url else { continue }
            let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: url))
            XCTAssertEqual(manifest.id, name)
            let issues = ManifestValidation.validate(manifest)
            XCTAssertTrue(issues.isEmpty, "\(name) should be valid, got: \(issues)")
        }
    }
}
