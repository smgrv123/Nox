import AideCore
import CommandRouter
import DangerousCommandScanner
import Foundation
import SkillManifest
import SkillRegistry
import XCTest

@testable import CommandDispatcher

// MARK: - Mocks

final class MockCommandScanner: CommandScanning, @unchecked Sendable {
    var verdict: ScanVerdict = .clean
    var failIfCalled = false
    private(set) var scanCallCount = 0
    private(set) var lastCommand: String?
    private(set) var lastContext: ScanContext?

    func scan(_ command: String, context: ScanContext) -> ScanVerdict {
        XCTAssertFalse(failIfCalled, "scanner must not be called on this path")
        scanCallCount += 1
        lastCommand = command
        lastContext = context
        return verdict
    }
}

final class MockBuiltinSkillExecutor: BuiltinSkillExecutor, @unchecked Sendable {
    var result: Result<SkillResult, Error> = .success(SkillResult(summary: "ok"))
    var failIfCalled = false
    private(set) var executeCallCount = 0
    private(set) var lastSkillID: String?
    private(set) var lastParameters: JSONValue?

    func execute(skillID: String, parameters: JSONValue) async throws -> SkillResult {
        XCTAssertFalse(failIfCalled, "executor must not be called on this path")
        executeCallCount += 1
        lastSkillID = skillID
        lastParameters = parameters
        return try result.get()
    }
}

struct ExecutorBoom: LocalizedError {
    var errorDescription: String? { "skill exploded" }
}

// MARK: - Registry spy

actor SpySkillRegistry: SkillRegistering {
    private let inner: InMemorySkillRegistry
    private(set) var validateCallCount = 0
    private(set) var manifestCallCount = 0

    init(manifests: [Manifest]) {
        self.inner = InMemorySkillRegistry(manifests: manifests)
    }

    var skills: [Manifest] {
        get async { await inner.skills }
    }

    func manifest(for skillID: String) async -> Manifest? {
        manifestCallCount += 1
        return await inner.manifest(for: skillID)
    }

    func routerGrammar() async -> String {
        await inner.routerGrammar()
    }

    func routerPromptSkillCatalog() async -> String {
        await inner.routerPromptSkillCatalog()
    }

    func validate(
        parameters: JSONValue,
        for skillID: String
    ) async -> Result<Void, ParameterValidationError> {
        validateCallCount += 1
        return await inner.validate(parameters: parameters, for: skillID)
    }
}

// MARK: - Manifests

func makeDispatcherManifest(
    id: String,
    riskTier: RiskTier = .low,
    parameters: JSONValue = emptyObjectSchema()
) -> Manifest {
    Manifest(
        schemaVersion: 1,
        id: id,
        kind: .builtin,
        displayName: id,
        description: "A test skill used by CommandDispatcher tests.",
        utteranceExamples: [],
        parameters: parameters,
        permissions: ManifestPermissions(),
        schedule: nil,
        riskTier: riskTier,
        enabled: true,
        scriptRef: nil,
        scriptSha256: nil,
        timeoutSeconds: 60,
        failureState: FailureState(),
        createdAt: nil,
        updatedAt: nil,
        generatedBy: .builtin
    )
}

func emptyObjectSchema() -> JSONValue {
    .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([]),
        "properties": .object([:]),
    ])
}

func objectSchema(
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

func stringType() -> JSONValue {
    .object(["type": .string("string")])
}

func integerType() -> JSONValue {
    .object(["type": .string("integer")])
}

func openApplicationManifest(riskTier: RiskTier = .low) -> Manifest {
    makeDispatcherManifest(
        id: "open_application",
        riskTier: riskTier,
        parameters: objectSchema(
            required: ["app_name"],
            properties: ["app_name": stringType()]
        )
    )
}

func calculateManifest() -> Manifest {
    makeDispatcherManifest(
        id: "calculate",
        parameters: objectSchema(
            required: ["expression"],
            properties: ["expression": stringType()]
        )
    )
}

func currentTimeManifest() -> Manifest {
    makeDispatcherManifest(id: "current_time")
}

func generalQAManifest() -> Manifest {
    makeDispatcherManifest(
        id: "general_qa",
        parameters: objectSchema(
            required: ["question"],
            properties: ["question": stringType()]
        )
    )
}

func screenQAManifest() -> Manifest {
    makeDispatcherManifest(
        id: "screen_qa",
        parameters: objectSchema(
            required: ["question"],
            properties: ["question": stringType()]
        )
    )
}

// MARK: - Intents

func routedIntent(
    skillID: String?,
    intent: String = "open Safari",
    parameters: JSONValue = .object(["app_name": .string("Safari")]),
    logprobMean: Float
) -> RoutedIntent {
    RoutedIntent(
        decision: RouterDecision(intent: intent, skillID: skillID, parameters: parameters),
        confidence: RoutingConfidence(
            idSelectingTokenCount: 1,
            logprobSum: logprobMean,
            logprobMean: logprobMean
        )
    )
}

func makeDispatcher(
    manifests: [Manifest],
    scanner: MockCommandScanner = MockCommandScanner(),
    executor: MockBuiltinSkillExecutor = MockBuiltinSkillExecutor(),
    thresholds: RoutingThresholds = RoutingThresholds(routeHigh: -0.15, routeLow: -0.7)
) -> CommandDispatcher {
    CommandDispatcher(
        registry: InMemorySkillRegistry(manifests: manifests),
        scanner: scanner,
        executor: executor,
        thresholds: thresholds
    )
}

func sampleFinding(
    rule: RuleID = .recursiveDelete,
    severity: Severity = .confirm,
    explanation: String = "recursive delete"
) -> Finding {
    Finding(
        rule: rule,
        severity: severity,
        matchedText: "rm -rf",
        explanation: explanation
    )
}
