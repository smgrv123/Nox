import DangerousCommandScanner
import Foundation
import LLMRuntime
import SpeechToText

@testable import Dictation

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

@MainActor
final class RecordingInserter: TextInserting {
    var focus = InsertionFocus(bundleID: "com.apple.TextEdit", accessibilityTrusted: true)
    var result: InsertionResult = .insertedViaPaste
    private(set) var inserted: [String] = []
    private(set) var copied: [String] = []

    func resolveFocus() async -> InsertionFocus { focus }

    func insert(_ text: String) async -> InsertionResult {
        inserted.append(text)
        return result
    }

    func copyToClipboard(_ text: String) async {
        copied.append(text)
    }
}

final class RecordingCommandScanner: CommandScanning, @unchecked Sendable {
    var verdict: ScanVerdict = .clean
    private(set) var scanCallCount = 0
    private(set) var lastCommand: String?
    private(set) var lastContext: ScanContext?

    func scan(_ command: String, context: ScanContext) -> ScanVerdict {
        scanCallCount += 1
        lastCommand = command
        lastContext = context
        return verdict
    }
}

func passingTranscription(text: String = "hello world") -> Transcription {
    Transcription(
        text: text,
        language: "en",
        segments: [
            Segment(
                text: text, tStart: 0, tEnd: 1.2,
                avgLogprob: -0.30, noSpeechProb: 0.02, compressionRatio: 1.4, tokenCount: 4)
        ])
}

func silentTranscription() -> Transcription {
    Transcription(text: "", language: "en", segments: [])
}

func confirmFinding(
    explanation: String = "Voice-dictated command targeting a terminal requires confirmation."
) -> Finding {
    Finding(
        rule: .dictationIntoTerminal,
        severity: .confirm,
        matchedText: "dictation → com.apple.Terminal",
        explanation: explanation)
}

func hardBlockFinding(explanation: String = "Privilege escalation via sudo is never permitted.") -> Finding {
    Finding(
        rule: .privilegeEscalation,
        severity: .hardBlock,
        matchedText: "sudo",
        explanation: explanation)
}

let dictationTestPCM = PCMBuffer(
    samples: [0.1, -0.1, 0.2], sampleRate: PCMBuffer.whisperSampleRate)

enum DictationTestError: Error {
    case endpointUnavailable
}

func dictationTestEndpoint(isLocal: Bool = true) -> LLMEndpoint {
    LLMEndpoint(
        baseURL: URL(string: "http://127.0.0.1:1")!,
        model: "test",
        isLocal: isLocal)
}

final class RecordingHistorySink: @unchecked Sendable {
    private(set) var entries: [DictationHistoryEntry] = []

    func append(_ entry: DictationHistoryEntry) {
        entries.append(entry)
    }
}

@MainActor
func makeDictationDriver(
    engine: MockSTTEngine,
    capture: FakeCaptureBuffer,
    inserter: RecordingInserter,
    scanner: any CommandScanning = RecordingCommandScanner(),
    llm: any LLMClient = MockLLMClient(),
    resolveEndpoint: @escaping @Sendable () async throws -> LLMEndpoint = {
        throw DictationTestError.endpointUnavailable
    },
    tonePreset: @escaping @Sendable () -> TonePreset = { .asIs },
    cleanupEnabled: @escaping @Sendable () -> Bool = { true },
    sidecarReady: @escaping @Sendable () async -> Bool = { true },
    appendHistory: @escaping @Sendable (DictationHistoryEntry) -> Void = { _ in }
) -> DictationDriver {
    DictationDriver(
        engine: engine,
        capture: capture,
        preGate: SegmentPreGate(thresholds: .provisional),
        inserter: inserter,
        scanner: scanner,
        llm: llm,
        resolveEndpoint: resolveEndpoint,
        tonePreset: tonePreset,
        cleanupEnabled: cleanupEnabled,
        sidecarReady: sidecarReady,
        appendHistory: appendHistory)
}

@MainActor
struct TerminalDictationSetup {
    let inserter: RecordingInserter
    let scanner: RecordingCommandScanner
    let driver: DictationDriver
}
