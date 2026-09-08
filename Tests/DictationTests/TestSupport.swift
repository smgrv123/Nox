import DangerousCommandScanner
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
    var result: InsertionResult = .insertedViaAX
    private(set) var inserted: [(text: String, plan: InsertionPlan)] = []

    func resolveFocus() async -> InsertionFocus { focus }

    func insert(_ text: String, plan: InsertionPlan) async -> InsertionResult {
        inserted.append((text, plan))
        return result
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

@MainActor
func makeDictationDriver(
    engine: MockSTTEngine,
    capture: FakeCaptureBuffer,
    inserter: RecordingInserter,
    scanner: any CommandScanning = RecordingCommandScanner(),
    overrides: @escaping @Sendable () -> [String: AppInsertionOverride] = { [:] }
) -> DictationDriver {
    DictationDriver(
        engine: engine,
        capture: capture,
        preGate: SegmentPreGate(thresholds: .provisional),
        inserter: inserter,
        scanner: scanner,
        overrides: overrides)
}

@MainActor
struct TerminalDictationSetup {
    let inserter: RecordingInserter
    let scanner: RecordingCommandScanner
    let driver: DictationDriver
}
