import SkillManifest
import XCTest

@testable import SkillRegistry

final class GBNFGrammarAssemblerTests: XCTestCase {

    func testThreeSkillGrammarIsDiscriminatedUnionWithIntentFirstAndNull() async {
        let registry = InMemorySkillRegistry(manifests: [
            makeOpenApplication(),
            makeSetTimer(),
            makeGeneralQA(),
        ])

        let grammar = await registry.routerGrammar()

        XCTAssertTrue(
            grammar.contains(#"root ::= "{" ws "\"intent\":" ws string "," ws skill "}" ws"#),
            "root must emit intent first, then the skill alternative. Grammar:\n\(grammar)"
        )
        XCTAssertTrue(
            grammar.contains("skill ::= s-general_qa | s-open_application | s-screen_qa | s-set_timer | s-null"),
            "skill alternatives must be a discriminated union sorted by id, with s-null last. Grammar:\n\(grammar)"
        )
        XCTAssertTrue(
            grammar.contains(
                #"s-open_application ::= "\"skill_id\":" ws "\"open_application\"" "," ws "#
                    + #""\"parameters\":" ws "{" ws "\"app_name\":" ws string ws "}""#
            ),
            "open_application alternative must pin the skill_id literal. Grammar:\n\(grammar)"
        )
        XCTAssertTrue(
            grammar.contains(#"s-null ::= "\"skill_id\":" ws "null" "," ws "\"parameters\":" ws "{" ws "}""#),
            "null alternative must be present. Grammar:\n\(grammar)"
        )
    }

    func testGrammarIncludesGeneralQAAndScreenQAWhenRegistered() async {
        let registry = InMemorySkillRegistry(manifests: [
            makeGeneralQA(),
            makeScreenQA(),
            makeOpenApplication(),
        ])

        let grammar = await registry.routerGrammar()

        XCTAssertTrue(grammar.contains("s-general_qa"), "grammar:\n\(grammar)")
        XCTAssertTrue(grammar.contains("s-screen_qa"), "grammar:\n\(grammar)")
        XCTAssertTrue(grammar.contains(#""\"skill_id\":" ws "\"general_qa\""#), "grammar:\n\(grammar)")
        XCTAssertTrue(grammar.contains(#""\"skill_id\":" ws "\"screen_qa\""#), "grammar:\n\(grammar)")
        XCTAssertTrue(
            grammar.contains("skill ::= s-general_qa | s-open_application | s-screen_qa | s-null"),
            "reserved targets are ordinary manifests, ordered by id. Grammar:\n\(grammar)"
        )
    }

    func testGrammarIsDeterministicAndStablyOrderedByID() async {
        let openApp = makeOpenApplication()
        let timer = makeSetTimer()
        let generalQA = makeGeneralQA()
        let first = InMemorySkillRegistry(manifests: [openApp, timer, generalQA])
        let second = InMemorySkillRegistry(manifests: [generalQA, openApp, timer])

        let grammarA = await first.routerGrammar()
        let grammarB = await second.routerGrammar()

        XCTAssertEqual(grammarA, grammarB)
        XCTAssertTrue(
            grammarA.contains("skill ::= s-general_qa | s-open_application | s-screen_qa | s-set_timer | s-null")
        )
    }

    func testGrammarOmitsDisabledAndInvalidManifests() async {
        let registry = InMemorySkillRegistry(manifests: [
            makeOpenApplication(),
            makeManifest(id: "set_timer", enabled: false),
            makeManifest(id: "BAD"),
        ])

        let grammar = await registry.routerGrammar()

        XCTAssertTrue(grammar.contains("s-open_application"))
        XCTAssertFalse(grammar.contains("s-set_timer"))
        XCTAssertFalse(grammar.contains("s-BAD"))
        XCTAssertTrue(
            grammar.contains("skill ::= s-general_qa | s-open_application | s-screen_qa | s-null")
        )
    }

    func testGrammarCompilesRequiredStringAndOptionalStringParameters() async {
        let registry = InMemorySkillRegistry(manifests: [
            makeOpenApplication(),
            makeSetTimer(),
        ])

        let grammar = await registry.routerGrammar()

        XCTAssertTrue(
            grammar.contains(#""\"app_name\":" ws string"#),
            "open_application required string. Grammar:\n\(grammar)"
        )
        XCTAssertTrue(
            grammar.contains(#""\"duration_seconds\":" ws integer"#),
            "set_timer required integer. Grammar:\n\(grammar)"
        )
        XCTAssertTrue(
            grammar.contains(#"( "," ws "\"label\":" ws string )?"#),
            "set_timer optional label. Grammar:\n\(grammar)"
        )
    }

    func testGrammarAlwaysAppendsSharedJSONTerminals() async {
        let registry = InMemorySkillRegistry(manifests: [makeGeneralQA()])
        let grammar = await registry.routerGrammar()

        XCTAssertTrue(grammar.contains(#"string ::= "\"" char* "\"""#), "grammar:\n\(grammar)")
        XCTAssertTrue(grammar.contains(#"char ::= [^"\\\x00-\x1F]"#), "grammar:\n\(grammar)")
        XCTAssertTrue(grammar.contains("hex ::= [0-9a-fA-F]"), "grammar:\n\(grammar)")
        XCTAssertTrue(grammar.contains(#"integer ::= "-"? ("0" | [1-9] [0-9]*)"#), "grammar:\n\(grammar)")
        XCTAssertTrue(grammar.contains("number ::= "), "grammar:\n\(grammar)")
        XCTAssertTrue(grammar.contains(#"boolean ::= "true" | "false""#), "grammar:\n\(grammar)")
        XCTAssertTrue(grammar.contains(#"ws ::= ([ \t\n])*"#), "grammar:\n\(grammar)")
    }

    func testGrammarCompilesEnumAsQuotedLiteralAlternation() async {
        let manifest = makeManifest(
            id: "media_control",
            description: "Control media playback: play, pause, skip to next or previous track.",
            parameters: objectSchema(
                required: ["action"],
                properties: [
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("play"),
                            .string("pause"),
                            .string("toggle"),
                        ]),
                    ])
                ]
            )
        )
        let registry = InMemorySkillRegistry(manifests: [manifest])
        let grammar = await registry.routerGrammar()

        XCTAssertTrue(
            grammar.contains(#""\"action\":" ws ("\"play\"" | "\"pause\"" | "\"toggle\"")"#),
            "enum must be a parenthesized literal alternation. Grammar:\n\(grammar)"
        )
    }

    func testGrammarCompilesArrayOfStrings() async {
        let manifest = makeManifest(
            id: "tag_items",
            description: "Attach one or more tags to the current item.",
            parameters: objectSchema(
                required: ["tags"],
                properties: [
                    "tags": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ])
                ]
            )
        )
        let registry = InMemorySkillRegistry(manifests: [manifest])
        let grammar = await registry.routerGrammar()

        XCTAssertTrue(
            grammar.contains(#""\"tags\":" ws "[" ( string ( "," ws string )* )? "]""#),
            "array shape per LLD §4.4. Grammar:\n\(grammar)"
        )
    }

    func testGrammarAlwaysIncludesReservedTargetsEvenWhenNotRegistered() async {
        let registry = InMemorySkillRegistry(manifests: [makeOpenApplication()])
        let grammar = await registry.routerGrammar()

        XCTAssertTrue(
            grammar.contains("skill ::= s-general_qa | s-open_application | s-screen_qa | s-null"),
            "reserved general_qa and screen_qa must always be present, sorted by id, s-null last. Grammar:\n\(grammar)"
        )
        XCTAssertTrue(
            grammar.contains(
                #"s-general_qa ::= "\"skill_id\":" ws "\"general_qa\"" "," ws "\"parameters\":" ws "{" ws "\"question\":" ws string ws "}""#
            ),
            "unregistered general_qa must use LLD §2.2.2 question:string shape. Grammar:\n\(grammar)"
        )
        XCTAssertTrue(
            grammar.contains(
                #"s-screen_qa ::= "\"skill_id\":" ws "\"screen_qa\"" "," ws "\"parameters\":" ws "{" ws "\"question\":" ws string ws "}""#
            ),
            "unregistered screen_qa must use LLD §2.2.2 question:string shape. Grammar:\n\(grammar)"
        )
        XCTAssertTrue(
            grammar.contains(
                #"s-open_application ::= "\"skill_id\":" ws "\"open_application\"" "," ws "#
                    + #""\"parameters\":" ws "{" ws "\"app_name\":" ws string ws "}""#
            ),
            "registered open_application must keep its own parameters. Grammar:\n\(grammar)"
        )
        XCTAssertTrue(
            grammar.contains(#"s-null ::= "\"skill_id\":" ws "null" "," ws "\"parameters\":" ws "{" ws "}""#),
            "null alternative must be present. Grammar:\n\(grammar)"
        )
    }

    func testGrammarCompilesEmptyParameterObject() async {
        let registry = InMemorySkillRegistry(manifests: [
            makeManifest(
                id: "current_time",
                description: "Tell the user the current date, time, or both in their local timezone."
            )
        ])
        let grammar = await registry.routerGrammar()

        XCTAssertTrue(
            grammar.contains(
                #"s-current_time ::= "\"skill_id\":" ws "\"current_time\"" "," ws "\"parameters\":" ws "{" ws "}""#),
            "empty properties must compile to an empty JSON object. Grammar:\n\(grammar)"
        )
    }

    func testGrammarCompilesNestedObjectAndBooleanAndNumber() async {
        let manifest = makeManifest(
            id: "record_event",
            description: "Record an event with a nested payload and a numeric amount.",
            parameters: objectSchema(
                required: ["amount", "ok", "meta"],
                properties: [
                    "amount": .object(["type": .string("number")]),
                    "ok": .object(["type": .string("boolean")]),
                    "meta": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "required": .array([.string("source")]),
                        "properties": .object(["source": stringType()]),
                    ]),
                ]
            )
        )
        let registry = InMemorySkillRegistry(manifests: [manifest])
        let grammar = await registry.routerGrammar()

        XCTAssertTrue(grammar.contains(#""\"amount\":" ws number"#), "grammar:\n\(grammar)")
        XCTAssertTrue(grammar.contains(#""\"ok\":" ws boolean"#), "grammar:\n\(grammar)")
        XCTAssertTrue(
            grammar.contains(#""\"meta\":" ws "{" ws "\"source\":" ws string ws "}""#),
            "nested object must be inlined. Grammar:\n\(grammar)"
        )
    }
}

// MARK: - Built-in-shaped fixtures

func makeOpenApplication() -> Manifest {
    makeManifest(
        id: "open_application",
        description: "Launch or switch focus to a macOS application the user names.",
        utteranceExamples: ["open Safari", "launch Xcode", "switch to Notes"],
        parameters: objectSchema(
            required: ["app_name"],
            properties: ["app_name": stringType()]
        )
    )
}

func makeSetTimer() -> Manifest {
    makeManifest(
        id: "set_timer",
        description: "Set a countdown timer for the specified duration and optionally name it.",
        utteranceExamples: ["set a timer for 5 minutes", "timer 30 seconds"],
        parameters: objectSchema(
            required: ["duration_seconds"],
            properties: [
                "duration_seconds": integerType(),
                "label": stringType(),
            ]
        )
    )
}

func makeGeneralQA() -> Manifest {
    makeManifest(
        id: "general_qa",
        description: "Answer a general knowledge question using the local LLM.",
        utteranceExamples: ["who wrote Hamlet", "what is the capital of France"],
        parameters: objectSchema(
            required: ["question"],
            properties: ["question": stringType()]
        )
    )
}

func makeScreenQA() -> Manifest {
    makeManifest(
        id: "screen_qa",
        description: "Answer a question about what is currently visible on the user's screen.",
        utteranceExamples: ["what's on my screen", "read the error message"],
        parameters: objectSchema(
            required: ["question"],
            properties: ["question": stringType()]
        )
    )
}
