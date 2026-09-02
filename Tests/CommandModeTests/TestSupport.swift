import AideCore
import CommandDispatcher
import CommandRouter
import DangerousCommandScanner
import Foundation
import LLMRuntime
import SkillManifest
import SkillRegistry
import SpeechToText
import XCTest

@testable import CommandMode

// MARK: - Capture fake (STTVoiceSessionDriverTests idiom)

actor FakeCaptureBuffer: AudioCaptureBuffer {
    enum CaptureError: Error { case micDenied }

    private let utterance: PCMBuffer
    private let startFails: Bool
    private(set) var startCount = 0
    private(set) var finalizeCount = 0
    private(set) var discardCount = 0

    init(finalizeReturns utterance: PCMBuffer, startFails: Bool = false) {
        self.utterance = utterance
        self.startFails = startFails
    }

    func start() async throws {
        startCount += 1
        if startFails { throw CaptureError.micDenied }
    }
    func append(_ frames: PCMBuffer) async {}
    func finalize() async -> PCMBuffer {
        finalizeCount += 1
        return utterance
    }
    func discard() async { discardCount += 1 }
}

// MARK: - Dispatcher mocks (CommandDispatcherTests pattern)

final class MockCommandScanner: CommandScanning, @unchecked Sendable {
    var verdict: ScanVerdict = .clean
    var failIfCalled = false
    private(set) var scanCallCount = 0

    func scan(_ command: String, context: ScanContext) -> ScanVerdict {
        XCTAssertFalse(failIfCalled, "scanner must not be called on this path")
        scanCallCount += 1
        return verdict
    }
}

final class MockBuiltinSkillExecutor: BuiltinSkillExecutor, @unchecked Sendable {
    var result: Result<SkillResult, Error> = .success(SkillResult(summary: "ok"))
    var failIfCalled = false
    private(set) var executeCallCount = 0

    func execute(skillID: String, parameters: JSONValue) async throws -> SkillResult {
        XCTAssertFalse(failIfCalled, "executor must not be called on this path")
        executeCallCount += 1
        return try result.get()
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
        description: "A test skill used by CommandMode tests.",
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

func objectSchema(required: [String], properties: [String: JSONValue]) -> JSONValue {
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

// MARK: - UTF-8 range helper (CommandRouterTests)

func utf8Range(of snippet: String, in raw: String) throws -> Range<Int> {
    let haystack = Array(raw.utf8)
    let needle = Array(snippet.utf8)
    guard let start = haystack.firstRange(of: needle)?.lowerBound else {
        struct SnippetNotFound: Error {}
        throw SnippetNotFound()
    }
    return start..<(start + needle.count)
}

func passingTranscription(text: String) -> Transcription {
    Transcription(
        text: text,
        language: "en",
        segments: [
            Segment(
                text: text, tStart: 0, tEnd: 2,
                avgLogprob: -0.30, noSpeechProb: 0.02, compressionRatio: 1.4, tokenCount: 6)
        ])
}

/// Silence: no segments ⇒ the Pre-Gate returns `fail(.noSpeech)` (STT driver suite idiom).
func silentTranscription() -> Transcription {
    Transcription(text: "", language: "en", segments: [])
}

/// `MockSTTEngine` never throws. This local conformer exercises the model-not-ready path.
actor ThrowingSTTEngine: STTEngine {
    enum EngineError: Error { case modelMissing }

    func ensureLoaded() async throws {
        throw EngineError.modelMissing
    }

    func transcribe(
        _ pcm: PCMBuffer,
        language: LanguageHint,
        initialPrompt: String?
    ) async throws -> Transcription {
        throw EngineError.modelMissing
    }
}

// MARK: - Pipeline factory (CommandModeDriverTests)

let commandModePCM = PCMBuffer(
    samples: [0.1, -0.1, 0.2], sampleRate: PCMBuffer.whisperSampleRate)

let commandModeLocalEndpoint = LLMEndpoint(
    baseURL: URL(string: "http://127.0.0.1:5555")!, model: "test-model", isLocal: true)

let openSafariRaw =
    #"{"intent":"open Safari","skill_id":"open_application","parameters":{"app_name":"Safari"}}"#

struct RouteStub {
    var raw: String
    var skillLiteral: String
    var logprob: Float
}

struct ThrowingRouter: Routing {
    struct Boom: LocalizedError {
        var errorDescription: String? { "router down" }
    }

    func route(
        transcript: String,
        whisperAvgLogprob: Float,
        endpoint: LLMEndpoint
    ) async throws -> RoutedIntent {
        throw Boom()
    }
}

func openSafariRoute(logprob: Float) -> RouteStub {
    RouteStub(raw: openSafariRaw, skillLiteral: #""open_application""#, logprob: logprob)
}

func makeDriver(
    route: RouteStub,
    manifests: [Manifest] = [openApplicationManifest()],
    scanner: MockCommandScanner = MockCommandScanner(),
    executor: MockBuiltinSkillExecutor,
    logFileURL: URL? = nil,
    engine: (any STTEngine)? = nil,
    capture: FakeCaptureBuffer? = nil,
    router: (any Routing)? = nil
) async throws -> CommandModeDriver {
    let valueRange = try utf8Range(of: route.skillLiteral, in: route.raw)
    let completion = RouterCompletion(
        raw: route.raw,
        tokenLogprobs: [
            TokenLogprob(token: route.skillLiteral, logprob: route.logprob, byteRange: valueRange)
        ])
    let registry = InMemorySkillRegistry(manifests: manifests)
    let resolvedRouter: any Routing
    if let router {
        resolvedRouter = router
    } else {
        resolvedRouter = LocalCommandRouter(
            client: MockLLMClient(routeCompletion: completion),
            skillCatalog: await registry.routerPromptSkillCatalog(),
            grammar: await registry.routerGrammar()
        )
    }
    let dispatcher = CommandDispatcher(
        registry: registry,
        scanner: scanner,
        executor: executor,
        thresholds: .provisional
    )
    let logURL = try logFileURL ?? temporaryLogURL()
    return CommandModeDriver(
        engine: engine ?? MockSTTEngine(returning: passingTranscription(text: "open Safari")),
        capture: capture ?? FakeCaptureBuffer(finalizeReturns: commandModePCM),
        preGate: SegmentPreGate(thresholds: .provisional),
        router: resolvedRouter,
        dispatcher: dispatcher,
        registry: registry,
        logger: CalibrationLogger(fileURL: logURL),
        endpoint: commandModeLocalEndpoint
    )
}

func temporaryLogURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "aide-cmd-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "calibration.jsonl")
}

func waitForLog(at fileURL: URL) async throws -> [String: Any] {
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try decodedLog(at: fileURL)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return try decodedLog(at: fileURL)
}

func decodedLog(at fileURL: URL) throws -> [String: Any] {
    let text = try XCTUnwrap(String(bytes: try Data(contentsOf: fileURL), encoding: .utf8))
    let line = try XCTUnwrap(text.split(separator: "\n").first)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
}

extension XCTestCase {
    @MainActor
    func collectResult(from driver: CommandModeDriver) async -> [VoiceSessionUpdate] {
        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
            if case .confirmBack = update { resolved.fulfill() }
            if case .promptBack = update { resolved.fulfill() }
            if case .hardBlocked = update { resolved.fulfill() }
        }
        driver.begin(mode: .command)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)
        return updates
    }
}
