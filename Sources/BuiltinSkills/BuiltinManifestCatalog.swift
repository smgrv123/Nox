import AideCore
import SkillManifest

/// Canonical built-in skill manifests for the composition root and registry.
///
/// Parameter schemas match what each skill's `run(parameters:)` extracts.
/// Risk tiers follow LLD §4.2 as locked in `specs/P4-app-wiring.md`.
public enum BuiltinManifestCatalog {

    public static let all: [Manifest] = [
        currentTime,
        calculate,
        generalQA,
        screenQA,
        openApplication,
        quitApplication,
        setTimer,
        mediaControl,
        takeScreenshot,
        unitConversion,
    ]

    private static let currentTime = Manifest(
        id: "current_time",
        kind: .builtin,
        displayName: "Current Time",
        description:
            "Tell the user the current date, time, or both in a named IANA timezone, or local time when omitted.",
        utteranceExamples: ["what time is it", "what's the date", "current time in Tokyo"],
        parameters: objectSchema(
            required: [],
            properties: ["timezone": stringProperty(minLength: 1, maxLength: 64)]
        ),
        permissions: ManifestPermissions(),
        riskTier: .low
    )

    private static let calculate = Manifest(
        id: "calculate",
        kind: .builtin,
        displayName: "Calculate",
        description: "Evaluate a mathematical expression and return the result.",
        utteranceExamples: ["what is 42 times 7", "calculate 15% of 200", "what's 15% of 230"],
        parameters: objectSchema(
            required: ["expression"],
            properties: ["expression": stringProperty(minLength: 1, maxLength: 500)]
        ),
        permissions: ManifestPermissions(),
        riskTier: .low
    )

    private static let generalQA = Manifest(
        id: "general_qa",
        kind: .builtin,
        displayName: "General Q&A",
        description: "Answer a general knowledge question using the local LLM.",
        utteranceExamples: [
            "who wrote Hamlet",
            "what is the capital of France",
            "explain quantum computing",
        ],
        parameters: objectSchema(
            required: ["question"],
            properties: ["question": stringProperty(minLength: 1, maxLength: 2000)]
        ),
        permissions: ManifestPermissions(),
        riskTier: .low
    )

    private static let screenQA = Manifest(
        id: "screen_qa",
        kind: .builtin,
        displayName: "Screen Q&A",
        description: "Answer a question about what is currently visible on the user's screen.",
        utteranceExamples: [
            "what's on my screen",
            "read the error message",
            "summarize what I'm looking at",
        ],
        parameters: objectSchema(
            required: ["question"],
            properties: ["question": stringProperty(minLength: 1, maxLength: 2000)]
        ),
        permissions: ManifestPermissions(requires: ["screen_recording"]),
        riskTier: .low
    )

    private static let openApplication = Manifest(
        id: "open_application",
        kind: .builtin,
        displayName: "Open Application",
        description: "Launch or switch focus to a macOS application the user names.",
        utteranceExamples: ["open Safari", "launch Xcode", "switch to Notes"],
        parameters: objectSchema(
            required: ["app_name"],
            properties: ["app_name": stringProperty(minLength: 1, maxLength: 100)]
        ),
        permissions: ManifestPermissions(),
        riskTier: .confirm
    )

    private static let quitApplication = Manifest(
        id: "quit_application",
        kind: .builtin,
        displayName: "Quit Application",
        description: "Gracefully quit a running macOS application the user names.",
        utteranceExamples: ["quit Safari", "close Xcode", "kill Notes"],
        parameters: objectSchema(
            required: ["app_name"],
            properties: ["app_name": stringProperty(minLength: 1, maxLength: 100)]
        ),
        permissions: ManifestPermissions(),
        riskTier: .confirm
    )

    private static let setTimer = Manifest(
        id: "set_timer",
        kind: .builtin,
        displayName: "Set Timer",
        description: "Set a countdown timer for the specified duration and optionally name it.",
        utteranceExamples: [
            "set a timer for 5 minutes",
            "timer 30 seconds",
            "start a 10 minute timer called pasta",
        ],
        parameters: objectSchema(
            required: ["duration_seconds"],
            properties: [
                "duration_seconds": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(86400),
                ]),
                "label": stringProperty(maxLength: 80),
            ]
        ),
        permissions: ManifestPermissions(),
        riskTier: .confirm
    )

    private static let mediaControl = Manifest(
        id: "media_control",
        kind: .builtin,
        displayName: "Media Control",
        description: "Control media playback: play, pause, skip to next or previous track.",
        utteranceExamples: ["pause the music", "play", "next track", "skip song", "previous"],
        parameters: objectSchema(
            required: ["action"],
            properties: [
                "action": stringEnum(["play", "pause", "toggle", "next", "previous"])
            ]
        ),
        permissions: ManifestPermissions(),
        riskTier: .confirm
    )

    private static let takeScreenshot = Manifest(
        id: "take_screenshot",
        kind: .builtin,
        displayName: "Take Screenshot",
        description: "Capture a screenshot of the current screen or a selected region.",
        utteranceExamples: ["take a screenshot", "screenshot", "capture screen"],
        parameters: objectSchema(
            required: [],
            properties: [
                "region": stringEnum(["full", "window", "selection"], default: "full")
            ]
        ),
        permissions: ManifestPermissions(requires: ["screen_recording"]),
        riskTier: .alwaysConfirm
    )

    private static let unitConversion = Manifest(
        id: "unit_conversion",
        kind: .builtin,
        displayName: "Unit Conversion",
        description:
            "Convert a numeric value between length, mass, temperature, volume, speed, or area units.",
        utteranceExamples: [
            "convert 10 miles to kilometers",
            "how many pounds is 5 kilograms",
            "convert 32 fahrenheit to celsius",
        ],
        parameters: objectSchema(
            required: ["value", "from_unit", "to_unit"],
            properties: [
                "value": .object(["type": .string("number")]),
                "from_unit": stringProperty(minLength: 1, maxLength: 40),
                "to_unit": stringProperty(minLength: 1, maxLength: 40),
            ]
        ),
        permissions: ManifestPermissions(),
        riskTier: .low
    )
}

private func objectSchema(
    required: [String],
    properties: [String: JSONValue]
) -> JSONValue {
    .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array(required.map { .string($0) }),
        "properties": .object(properties),
    ])
}

private func stringProperty(minLength: Int? = nil, maxLength: Int? = nil) -> JSONValue {
    var schema: [String: JSONValue] = ["type": .string("string")]
    if let minLength {
        schema["minLength"] = .int(minLength)
    }
    if let maxLength {
        schema["maxLength"] = .int(maxLength)
    }
    return .object(schema)
}

private func stringEnum(_ values: [String], default defaultValue: String? = nil) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("string"),
        "enum": .array(values.map { .string($0) }),
    ]
    if let defaultValue {
        schema["default"] = .string(defaultValue)
    }
    return .object(schema)
}
