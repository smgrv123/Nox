import SkillManifest
import XCTest

@testable import SkillRegistry

final class GBNFParameterCompilerTests: XCTestCase {

    func testUnknownJSONSchemaTypeDoesNotEmitStringTerminal() {
        let schema = objectSchema(
            required: ["when", "title"],
            properties: [
                "when": .object(["type": .string("date")]),
                "title": stringType(),
            ]
        )

        let grammar = GBNFParameterCompiler.compileObject(schema)

        XCTAssertFalse(
            grammar.contains(#""\"when\":" ws string"#),
            "unknown JSON Schema type must not fail-open to the string terminal. Grammar:\n\(grammar)"
        )
        XCTAssertFalse(
            grammar.contains(#""\"when\":"#),
            "unknown-type property must be skipped, not emitted with another terminal. Grammar:\n\(grammar)"
        )
        XCTAssertTrue(
            grammar.contains(#""\"title\":" ws string"#),
            "known string sibling must still compile. Grammar:\n\(grammar)"
        )
    }

    func testCompileTypeReturnsNilForUnknownJSONSchemaType() {
        let compiled = GBNFParameterCompiler.compileType(.object(["type": .string("date")]))
        XCTAssertNil(compiled, "unknown type must fail closed, not default to string")
    }

    func testEnumStillCompilesWhenJSONSchemaTypeIsUnknown() {
        let schema = objectSchema(
            required: ["when"],
            properties: [
                "when": .object([
                    "type": .string("date"),
                    "enum": .array([.string("today"), .string("tomorrow")]),
                ])
            ]
        )

        let grammar = GBNFParameterCompiler.compileObject(schema)

        XCTAssertTrue(
            grammar.contains(#""\"when\":" ws ("\"today\"" | "\"tomorrow\"")"#),
            "enum-first must still emit literals even when type is unknown. Grammar:\n\(grammar)"
        )
    }
}
