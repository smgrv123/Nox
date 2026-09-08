import AideCore
import DangerousCommandScanner
import Foundation
import LLMRuntime
import SpeechToText

/// Dictation-mode `VoiceSessionDriver`: capture → transcribe → Pre-Gate →
/// terminal-destination scan → tone cleanup → insert at the caret
/// (plans/P5a-dictation-core.md Phase 3). Overlay/coordinator stay unchanged;
/// the mux swaps this in for `STTVoiceSessionDriver` on `.dictation`.
///
/// Depends on `STTEngine`, `AudioCaptureBuffer`, `SegmentPreGate`,
/// `TextInserting`, `CommandScanning`, and `LLMClient` — tests inject mocks;
/// `App/TextInserterLive.swift` is the AppKit shell. Never `InferenceClient`.
public final class DictationDriver: VoiceSessionDriver {

    public var onUpdate: ((VoiceSessionUpdate) -> Void)?

    public static let reAskSummary = "I didn't catch that — try again."
    public static let modelNotReadySummary = "Speech model isn't ready yet."
    public static let microphoneUnavailableSummary = "Couldn't access the microphone."
    public static let cleanupFailedSummary = "Inserted raw — cleanup failed."

    private let engine: any STTEngine
    private let capture: any AudioCaptureBuffer
    private let preGate: SegmentPreGate
    private let inserter: any TextInserting
    private let scanner: any CommandScanning
    private let llm: any LLMClient
    private let resolveEndpoint: @Sendable () async throws -> LLMEndpoint
    private let tonePreset: @Sendable () -> TonePreset
    private let planner = InsertionPlanner()
    private let overrides: @Sendable () -> [String: AppInsertionOverride]
    private let makeInitialPrompt: @Sendable () async -> String?
    private let dictionarySubstitutions: @Sendable () async -> String

    private var generation = 0
    private var activeMode: VoiceSessionMode = .dictation
    private var captureTask: Task<Bool, Never>?
    private var pendingInsert: PendingInsert?

    private struct PendingInsert {
        let text: String
        let plan: InsertionPlan
        let generation: Int
    }

    public init(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate,
        inserter: any TextInserting,
        scanner: any CommandScanning,
        llm: any LLMClient,
        resolveEndpoint: @escaping @Sendable () async throws -> LLMEndpoint,
        tonePreset: @escaping @Sendable () -> TonePreset = { .asIs },
        overrides: @escaping @Sendable () -> [String: AppInsertionOverride] = { [:] },
        makeInitialPrompt: @escaping @Sendable () async -> String? = { nil },
        dictionarySubstitutions: @escaping @Sendable () async -> String = { "" }
    ) {
        self.engine = engine
        self.capture = capture
        self.preGate = preGate
        self.inserter = inserter
        self.scanner = scanner
        self.llm = llm
        self.resolveEndpoint = resolveEndpoint
        self.tonePreset = tonePreset
        self.overrides = overrides
        self.makeInitialPrompt = makeInitialPrompt
        self.dictionarySubstitutions = dictionarySubstitutions
    }

    public func begin(mode: VoiceSessionMode) {
        generation &+= 1
        pendingInsert = nil
        activeMode = mode

        captureTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                try await self.capture.start()
                return true
            } catch {
                return false
            }
        }

        Task { [engine] in try? await engine.ensureLoaded() }
    }

    public func end() {
        let generation = self.generation
        let mode = activeMode
        let capture = self.capture
        let started = captureTask

        Task { @MainActor [weak self] in
            guard let self else { return }
            let didStart = await started?.value ?? true
            guard self.generation == generation else { return }

            guard didStart else {
                await capture.discard()
                self.deliver(.result(Self.degraded(Self.microphoneUnavailableSummary)), generation: generation)
                return
            }

            let pcm = await capture.finalize()
            guard self.generation == generation else { return }
            await self.resolve(pcm, mode: mode, generation: generation)
        }
    }

    public func cancel() {
        generation &+= 1
        pendingInsert = nil
        let capture = self.capture
        let started = captureTask
        Task {
            _ = await started?.value
            await capture.discard()
        }
    }

    public func approve() {
        guard let pending = pendingInsert else { return }
        pendingInsert = nil
        let generation = pending.generation
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            await self.performInsert(pending.text, plan: pending.plan, generation: generation)
        }
    }

    public func reject() {
        guard let pending = pendingInsert else { return }
        pendingInsert = nil
        let generation = pending.generation
        let text = pending.text
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            self.deliver(
                .result(VoiceSessionResult(transcript: text, summary: "Cancelled.")),
                generation: generation)
        }
    }

    @MainActor
    private func resolve(_ pcm: PCMBuffer, mode: VoiceSessionMode, generation: Int) async {
        do {
            try await engine.ensureLoaded()
            let normalized = Self.peakNormalize(pcm)
            let prompt = await makeInitialPrompt()
            let transcription = try await engine.transcribe(
                normalized, language: .auto, initialPrompt: prompt)
            guard self.generation == generation else { return }

            switch preGate.evaluate(transcription, mode: mode) {
            case .pass(let text, _):
                await scanThenInsert(text, generation: generation)
            case .fail:
                deliver(.result(Self.degraded(Self.reAskSummary)), generation: generation)
            }
        } catch {
            deliver(.result(Self.degraded(Self.modelNotReadySummary)), generation: generation)
        }
    }

    @MainActor
    private func scanThenInsert(_ text: String, generation: Int) async {
        let focus = await inserter.resolveFocus()
        let override = focus.bundleID.flatMap { overrides()[$0] }
        let isTerminal = focus.bundleID.map(TerminalBundleAllowlist.contains) ?? false
        let plan = planner.plan(focus: focus, override: override, isTerminal: isTerminal)

        if isTerminal, let bundleID = focus.bundleID {
            let verdict = scanner.scan(
                text,
                context: ScanContext(
                    channel: .dictatedOneOff,
                    destinationBundleID: bundleID,
                    manifestID: nil))
            switch verdict {
            case .clean:
                break
            case .confirm:
                pendingInsert = PendingInsert(text: text, plan: plan, generation: generation)
                deliver(
                    .confirmBack(
                        ConfirmBackInfo(
                            transcript: text,
                            intent: text,
                            skillID: "dictation_insert",
                            riskTier: .alwaysConfirm)),
                    generation: generation)
                return
            case .hardBlock(let findings):
                deliver(
                    .hardBlocked(text, findings.first?.explanation ?? "Blocked"),
                    generation: generation)
                return
            }
        }

        await performInsert(text, plan: plan, generation: generation)
    }

    @MainActor
    private func performInsert(_ rawText: String, plan: InsertionPlan, generation: Int) async {
        let cleanup = await runDictationCleanup(
            raw: rawText,
            llm: llm,
            resolveEndpoint: resolveEndpoint,
            tonePreset: tonePreset,
            dictionarySubstitutions: dictionarySubstitutions)
        let insertion = await inserter.insert(cleanup.text, plan: plan)
        guard self.generation == generation else { return }

        deliver(.transcript(cleanup.text), generation: generation)
        switch insertion {
        case .insertedViaAX, .insertedViaPaste, .copiedToClipboard:
            deliver(
                .result(VoiceSessionResult(transcript: cleanup.text, summary: cleanup.resultSummary)),
                generation: generation)
        case .failed(let reason):
            deliver(
                .result(VoiceSessionResult(transcript: cleanup.text, summary: reason)),
                generation: generation)
        }
    }

    private static func peakNormalize(_ pcm: PCMBuffer) -> PCMBuffer {
        let targetPeak: Float = 0.9
        let maxAmp = pcm.samples.reduce(Float(0)) { max($0, abs($1)) }
        guard maxAmp > 0.001 else { return pcm }
        let gain = min(targetPeak / maxAmp, 20.0)
        guard gain > 1.05 else { return pcm }
        return PCMBuffer(samples: pcm.samples.map { $0 * gain }, sampleRate: pcm.sampleRate)
    }

    @MainActor
    private func deliver(_ update: VoiceSessionUpdate, generation: Int) {
        guard generation == self.generation else { return }
        onUpdate?(update)
    }

    private static func degraded(_ summary: String) -> VoiceSessionResult {
        VoiceSessionResult(transcript: "", summary: summary)
    }
}

private enum DictationCleanupOutcome {
    case cleaned(String)
    case skipped(String)
    case chatFailed(String)

    var text: String {
        switch self {
        case .cleaned(let text), .skipped(let text), .chatFailed(let text):
            return text
        }
    }

    var resultSummary: String {
        switch self {
        case .cleaned(let text), .skipped(let text):
            return text
        case .chatFailed:
            return DictationDriver.cleanupFailedSummary
        }
    }
}

private let dictationCleanupSampling = SamplingParams(
    temperature: 0.2, topP: 1.0, maxTokens: 1024, topLogprobs: 0)

private func runDictationCleanup(
    raw: String,
    llm: any LLMClient,
    resolveEndpoint: @Sendable () async throws -> LLMEndpoint,
    tonePreset: @Sendable () -> TonePreset,
    dictionarySubstitutions: @Sendable () async -> String
) async -> DictationCleanupOutcome {
    let endpoint: LLMEndpoint
    do {
        endpoint = try await resolveEndpoint()
    } catch {
        return .skipped(raw)
    }
    guard endpoint.isLocal else {
        return .skipped(raw)
    }

    do {
        let substitutions = await dictionarySubstitutions()
        let prompt = CleanupPromptBuilder.build(
            tone: tonePreset(),
            substitutions: substitutions,
            rawTranscript: raw)
        let stream = try await llm.chat(
            system: CleanupPromptBuilder.system,
            messages: [ChatMessage(role: .user, content: prompt)],
            params: dictationCleanupSampling,
            endpoint: endpoint,
            stream: false)
        var combined = ""
        for try await chunk in stream {
            combined += chunk.delta
        }
        return .cleaned(CleanupResponseSanitizer.sanitize(combined))
    } catch {
        return .chatFailed(raw)
    }
}
