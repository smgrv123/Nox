import BuiltinSkills
import XCTest

@testable import SkillRegistry

final class CorrectThatGrammarTests: XCTestCase {

    func testCorrectThatIsInFullCatalogGrammar() async {
        let registry = InMemorySkillRegistry(manifests: BuiltinManifestCatalog.all)
        let grammar = await registry.routerGrammar()
        XCTAssertTrue(
            grammar.contains(#""\"skill_id\":" ws "\"correct_that\""#),
            "full catalog grammar must include the correct_that skill_id literal. Grammar:\n\(grammar)")
    }
}
