import SkillManifest
import XCTest

@testable import SkillRegistry

final class ParameterValidatorTests: XCTestCase {

    func testValidatePassesCorrectlyTypedParameters() async {
        let registry = InMemorySkillRegistry(manifests: [makeOpenApplication()])
        let parameters = JSONValue.object(["app_name": .string("Safari")])

        let result = await registry.validate(parameters: parameters, for: "open_application")
        assertSuccess(result)
    }

    func testValidateRejectsMissingRequiredFields() async {
        let registry = InMemorySkillRegistry(manifests: [makeOpenApplication()])
        let parameters = JSONValue.object([:])

        let result = await registry.validate(parameters: parameters, for: "open_application")

        assertFailure(result, .missingRequiredField("app_name"))
    }

    func testValidateRejectsWrongTypeValues() async {
        let registry = InMemorySkillRegistry(manifests: [makeSetTimer()])
        let parameters = JSONValue.object(["duration_seconds": .string("five")])

        let result = await registry.validate(parameters: parameters, for: "set_timer")

        assertFailure(
            result,
            .typeMismatch(field: "duration_seconds", expected: "integer", actual: "string")
        )
    }

    func testValidateRejectsAdditionalPropertiesWhenFalse() async {
        let registry = InMemorySkillRegistry(manifests: [makeOpenApplication()])
        let parameters = JSONValue.object([
            "app_name": .string("Safari"),
            "extra": .string("nope"),
        ])

        let result = await registry.validate(parameters: parameters, for: "open_application")

        assertFailure(result, .additionalProperty("extra"))
    }

    func testValidateRejectsAdditionalPropertiesWhenFlagAbsent() async {
        let manifest = makeManifest(
            id: "open_application",
            description: "Launch or switch focus to a macOS application the user names.",
            parameters: objectSchema(
                required: ["app_name"],
                properties: ["app_name": stringType()],
                additionalProperties: nil
            )
        )
        let registry = InMemorySkillRegistry(manifests: [manifest])
        let parameters = JSONValue.object([
            "app_name": .string("Safari"),
            "sneaky": .bool(true),
        ])

        let result = await registry.validate(parameters: parameters, for: "open_application")

        assertFailure(result, .additionalProperty("sneaky"))
    }

    func testValidateRejectsUnknownSkillID() async {
        let registry = InMemorySkillRegistry(manifests: [makeOpenApplication()])
        let result = await registry.validate(
            parameters: .object(["app_name": .string("Safari")]),
            for: "not_a_skill"
        )

        assertFailure(result, .unknownSkillID("not_a_skill"))
    }

    func testValidateAcceptsOptionalFieldsWhenPresentAndWhenOmitted() async {
        let registry = InMemorySkillRegistry(manifests: [makeSetTimer()])

        let withLabel = await registry.validate(
            parameters: .object([
                "duration_seconds": .int(30),
                "label": .string("pasta"),
            ]),
            for: "set_timer"
        )
        let withoutLabel = await registry.validate(
            parameters: .object(["duration_seconds": .int(30)]),
            for: "set_timer"
        )

        assertSuccess(withLabel)
        assertSuccess(withoutLabel)
    }

    func testValidateRejectsInvalidEnumValue() async {
        let manifest = makeManifest(
            id: "media_control",
            description: "Control media playback: play, pause, skip to next or previous track.",
            parameters: objectSchema(
                required: ["action"],
                properties: [
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([.string("play"), .string("pause")]),
                    ])
                ]
            )
        )
        let registry = InMemorySkillRegistry(manifests: [manifest])
        let result = await registry.validate(
            parameters: .object(["action": .string("shuffle")]),
            for: "media_control"
        )

        assertFailure(result, .invalidEnumValue(field: "action", value: "shuffle"))
    }

    func testValidateRejectsNonObjectParameters() async {
        let registry = InMemorySkillRegistry(manifests: [makeOpenApplication()])
        let result = await registry.validate(parameters: .string("Safari"), for: "open_application")

        assertFailure(result, .parametersNotObject)
    }

    func testValidateAcceptsNestedObjectAndNumberAndBoolean() async {
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
        let result = await registry.validate(
            parameters: .object([
                "amount": .double(1.5),
                "ok": .bool(true),
                "meta": .object(["source": .string("voice")]),
            ]),
            for: "record_event"
        )
        assertSuccess(result)
    }

    func testValidateRejectsNestedAdditionalProperty() async {
        let manifest = makeManifest(
            id: "record_event",
            description: "Record an event with a nested payload and a numeric amount.",
            parameters: objectSchema(
                required: ["meta"],
                properties: [
                    "meta": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "required": .array([.string("source")]),
                        "properties": .object(["source": stringType()]),
                    ])
                ]
            )
        )
        let registry = InMemorySkillRegistry(manifests: [manifest])
        let result = await registry.validate(
            parameters: .object([
                "meta": .object([
                    "source": .string("voice"),
                    "extra": .string("nope"),
                ])
            ]),
            for: "record_event"
        )
        assertFailure(result, .additionalProperty("meta.extra"))
    }
}

extension ParameterValidatorTests {

    func testValidateRejectsIntegerBelowMinimum() async {
        let result = await validateField(
            id: "poll_interval",
            field: "interval_seconds",
            schema: typedSchema("integer", ["minimum": .int(30)]),
            value: .int(10)
        )
        assertFailure(
            result,
            .belowMinimum(field: "interval_seconds", value: "10", minimum: "30")
        )
    }

    func testValidateAcceptsIntegerAtMinimum() async {
        let result = await validateField(
            id: "poll_interval",
            field: "interval_seconds",
            schema: typedSchema("integer", ["minimum": .int(30)]),
            value: .int(30)
        )
        assertSuccess(result)
    }

    func testValidateRejectsNumberBelowMinimum() async {
        let result = await validateField(
            id: "record_amount",
            field: "amount",
            schema: typedSchema("number", ["minimum": .double(1.5)]),
            value: .double(1.0)
        )
        assertFailure(result, .belowMinimum(field: "amount", value: "1.0", minimum: "1.5"))
    }

    func testValidateDoesNotInventMinimumWhenAbsent() async {
        let registry = InMemorySkillRegistry(manifests: [makeSetTimer()])
        let result = await registry.validate(
            parameters: .object(["duration_seconds": .int(1)]),
            for: "set_timer"
        )
        assertSuccess(result)
    }

    func testValidateRejectsStringExceedingMaxLength() async {
        let result = await validateField(
            id: "open_application",
            field: "app_name",
            schema: typedSchema("string", ["maxLength": .int(5)]),
            value: .string("Safari")
        )
        assertFailure(result, .exceedsMaxLength(field: "app_name", length: 6, maxLength: 5))
    }

    func testValidateAcceptsStringAtMaxLength() async {
        let result = await validateField(
            id: "open_application",
            field: "app_name",
            schema: typedSchema("string", ["maxLength": .int(6)]),
            value: .string("Safari")
        )
        assertSuccess(result)
    }

    func testValidateDoesNotInventMaxLengthWhenAbsent() async {
        let registry = InMemorySkillRegistry(manifests: [makeOpenApplication()])
        let result = await registry.validate(
            parameters: .object(["app_name": .string(String(repeating: "a", count: 200))]),
            for: "open_application"
        )
        assertSuccess(result)
    }

    func testValidateRejectsStringBelowMinLength() async {
        let result = await validateField(
            id: "open_application",
            field: "app_name",
            schema: typedSchema("string", ["minLength": .int(1)]),
            value: .string("")
        )
        assertFailure(result, .belowMinLength(field: "app_name", length: 0, minLength: 1))
    }

    func testValidateDoesNotInventMinLengthWhenAbsent() async {
        let registry = InMemorySkillRegistry(manifests: [makeOpenApplication()])
        let result = await registry.validate(
            parameters: .object(["app_name": .string("")]),
            for: "open_application"
        )
        assertSuccess(result)
    }

    func testValidateRejectsStringNotMatchingPattern() async {
        let result = await validateField(
            id: "verify_hash",
            field: "digest",
            schema: typedSchema("string", ["pattern": .string("^[a-f0-9]{64}$")]),
            value: .string("not-a-hash")
        )
        assertFailure(
            result,
            .patternMismatch(field: "digest", value: "not-a-hash", pattern: "^[a-f0-9]{64}$")
        )
    }

    func testValidateAcceptsStringMatchingPattern() async {
        let result = await validateField(
            id: "verify_hash",
            field: "digest",
            schema: typedSchema("string", ["pattern": .string("^[a-f0-9]{64}$")]),
            value: .string(String(repeating: "ab", count: 32))
        )
        assertSuccess(result)
    }

    func testValidateDoesNotInventPatternWhenAbsent() async {
        let registry = InMemorySkillRegistry(manifests: [makeOpenApplication()])
        let result = await registry.validate(
            parameters: .object(["app_name": .string("Safari 26!")]),
            for: "open_application"
        )
        assertSuccess(result)
    }

    func testValidateRejectsNestedObjectValueBelowMinimum() async {
        let nested = typedSchema(
            "object",
            [
                "additionalProperties": .bool(false),
                "required": .array([.string("count")]),
                "properties": .object(["count": typedSchema("integer", ["minimum": .int(1)])]),
            ])
        let result = await validateField(
            id: "record_event",
            field: "meta",
            schema: nested,
            value: .object(["count": .int(0)])
        )
        assertFailure(result, .belowMinimum(field: "meta.count", value: "0", minimum: "1"))
    }

    func testValidateRejectsArrayItemExceedingMaxLength() async {
        let result = await validateField(
            id: "tag_item",
            field: "tags",
            schema: typedSchema(
                "array",
                [
                    "items": typedSchema("string", ["maxLength": .int(3)])
                ]),
            value: .array([.string("ok"), .string("long")])
        )
        assertFailure(result, .exceedsMaxLength(field: "tags[1]", length: 4, maxLength: 3))
    }
}

func typedSchema(_ type: String, _ keywords: [String: JSONValue] = [:]) -> JSONValue {
    var fields = keywords
    fields["type"] = .string(type)
    return .object(fields)
}

func validateField(
    id: String,
    field: String,
    schema: JSONValue,
    value: JSONValue
) async -> Result<Void, ParameterValidationError> {
    let manifest = makeManifest(
        id: id,
        parameters: objectSchema(required: [field], properties: [field: schema])
    )
    let registry = InMemorySkillRegistry(manifests: [manifest])
    return await registry.validate(parameters: .object([field: value]), for: id)
}

func assertSuccess(
    _ result: Result<Void, ParameterValidationError>,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if case .failure(let error) = result {
        XCTFail("expected success, got \(error)", file: file, line: line)
    }
}

func assertFailure(
    _ result: Result<Void, ParameterValidationError>,
    _ expected: ParameterValidationError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch result {
    case .success:
        XCTFail("expected \(expected), got success", file: file, line: line)
    case .failure(let error):
        XCTAssertEqual(error, expected, file: file, line: line)
    }
}
