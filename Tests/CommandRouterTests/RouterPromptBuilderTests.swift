import XCTest

@testable import CommandRouter

final class RouterPromptBuilderTests: XCTestCase {

    func testTemplateContainsLLDPlaceholders() {
        XCTAssertTrue(RouterPromptBuilder.template.contains("{{SKILL_CATALOG}}"))
        XCTAssertTrue(RouterPromptBuilder.template.contains("{{SESSION_CONTEXT}}"))
        XCTAssertTrue(RouterPromptBuilder.template.contains("{{TRANSCRIPT}}"))
        XCTAssertTrue(RouterPromptBuilder.template.contains("You are Aide's router."))
        XCTAssertTrue(RouterPromptBuilder.template.contains("general_qa"))
    }

    func testSubstitutesCatalogAndTranscript() {
        let prompt = RouterPromptBuilder().build(
            skillCatalog: "SKILL-CATALOG-HERE",
            transcript: "open safari")

        XCTAssertTrue(prompt.contains("SKILL-CATALOG-HERE"))
        XCTAssertTrue(prompt.contains("open safari"))
        XCTAssertFalse(prompt.contains("{{SKILL_CATALOG}}"))
        XCTAssertFalse(prompt.contains("{{TRANSCRIPT}}"))
        XCTAssertFalse(prompt.contains("{{SESSION_CONTEXT}}"))
    }

    func testSessionContextDefaultsToEmptyAndCanBeFilled() {
        let empty = RouterPromptBuilder().build(skillCatalog: "c", transcript: "t")
        XCTAssertFalse(empty.contains("{{SESSION_CONTEXT}}"))
        XCTAssertFalse(empty.contains("yesterday we opened Mail"))

        let filled = RouterPromptBuilder().build(
            skillCatalog: "c",
            transcript: "t",
            sessionContext: "yesterday we opened Mail")
        XCTAssertTrue(filled.contains("yesterday we opened Mail"))
    }
}
