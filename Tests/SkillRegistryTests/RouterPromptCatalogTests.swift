import SkillManifest
import XCTest

@testable import SkillRegistry

final class RouterPromptCatalogTests: XCTestCase {

    func testCatalogIncludesEachEnabledSkillDescriptionAndParameterSchema() async {
        let registry = InMemorySkillRegistry(manifests: [
            makeSetTimer(),
            makeOpenApplication(),
            makeManifest(id: "set_timer", enabled: false),
        ])

        let catalog = await registry.routerPromptSkillCatalog()

        XCTAssertTrue(catalog.contains("open_application"), "catalog:\n\(catalog)")
        XCTAssertTrue(
            catalog.contains("Launch or switch focus to a macOS application the user names."),
            "catalog:\n\(catalog)"
        )
        XCTAssertTrue(catalog.contains("app_name"), "catalog must summarize parameters:\n\(catalog)")

        XCTAssertTrue(catalog.contains("set_timer"), "catalog:\n\(catalog)")
        XCTAssertTrue(
            catalog.contains("Set a countdown timer for the specified duration and optionally name it."),
            "catalog:\n\(catalog)"
        )
        XCTAssertTrue(catalog.contains("duration_seconds"), "catalog:\n\(catalog)")
        XCTAssertTrue(catalog.contains("label"), "catalog:\n\(catalog)")
    }

    func testCatalogIsOrderedBySkillIDAndOmitsDisabled() async {
        let registry = InMemorySkillRegistry(manifests: [
            makeSetTimer(),
            makeGeneralQA(),
            makeOpenApplication(),
            makeManifest(id: "zebra_skill", enabled: false),
        ])

        let catalog = await registry.routerPromptSkillCatalog()

        let generalQA = catalog.range(of: "general_qa")
        let openApp = catalog.range(of: "open_application")
        let timer = catalog.range(of: "set_timer")
        XCTAssertNotNil(generalQA)
        XCTAssertNotNil(openApp)
        XCTAssertNotNil(timer)
        if let generalQA, let openApp, let timer {
            XCTAssertTrue(generalQA.lowerBound < openApp.lowerBound)
            XCTAssertTrue(openApp.lowerBound < timer.lowerBound)
        }
        XCTAssertFalse(catalog.contains("zebra_skill"))
    }

    func testCatalogIncludesUtteranceExamples() async {
        let registry = InMemorySkillRegistry(manifests: [makeOpenApplication()])
        let catalog = await registry.routerPromptSkillCatalog()

        XCTAssertTrue(catalog.contains("open Safari"), "catalog:\n\(catalog)")
        XCTAssertTrue(catalog.contains("launch Xcode"), "catalog:\n\(catalog)")
    }
}
