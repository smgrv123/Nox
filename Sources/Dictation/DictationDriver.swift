import AideCore
import DangerousCommandScanner
import Foundation
import LLMRuntime
import SpeechToText

/// Dictation-mode `VoiceSessionDriver`: capture → transcribe → Pre-Gate →
/// terminal-destination scan → tone cleanup → insert at the caret
/// (plans/P5a-dictation-core.md Phase 5). Overlay/coordinator stay unchanged;
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
    public static let sidecarNotReadySummary = "Inserted raw — language model wasn't ready."
    public static let copiedToClipboardSummary = "Couldn't insert — copied to clipboard instead."
    public static let accessibilityDeniedSummary =
        "Text insertion needs Accessibility. Enable Aide in System Settings."

    private let engine: any STTEngine
    private let capture: any AudioCaptureBuffer
    private let preGate: SegmentPreGate
    private let inserter: any TextInserting
    private let scanner: any CommandScanning
    private let llm: any LLMClient
    private let resolveEndpoint: @Sendable () async throws -> LLMEndpoint
    private let tonePreset: @Sendable () -> TonePreset
    private let cleanupEnabled: @Sendable () -> Bool
    private let sidecarReady: @Sendable () async -> Bool
    private let planner = InsertionPlanner()
    private let overrides: @Sendable () -> [String: AppInsertionOverride]
    private let makeInitialPrompt: @Sendable () async -> String?
    private let dictionarySubstitutions: @Sendable () async -> String
    private let recordOverride: @Sendable (String, AppInsertionOverride) -> Void
    private let appendHistory: @Sendable (DictationHistoryEntry) -> Void

    private var generation = 0
    private var activeMode: VoiceSessionMode = .dictation
    private var captureTask: Task<Bool, Never>?
    private var pendingInsert: PendingInsert?

    fileprivate struct PendingInsert {
        let text: String
        let plan: InsertionPlan
        let tone: TonePreset
        let generation: Int
        let focus: InsertionFocus
        let override: AppInsertionOverride?
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
        cleanupEnabled: @escaping @Sendable () -> Bool = { true },
        sidecarReady: @escaping @Sendable () async -> Bool = { true },
        makeInitialPrompt: @escaping @Sendable () async -> String? = { nil },
        dictionarySubstitutions: @escaping @Sendable () async -> String = { "" },
        recordOverride: @escaping @Sendable (String, AppInsertionOverride) -> Void = { _, _ in },
        appendHistory: @escaping @Sendable (DictationHistoryEntry) -> Void = { _ in }
    ) {
        self.engine = engine
        self.capture = capture
        self.preGate = preGate
        self.inserter = inserter
        self.scanner = scanner
        self.llm = llm
        self.resolveEndpoint = resolveEndpoint
        self.tonePreset = tonePreset
        self.cleanupEnabled = cleanupEnabled
        self.sidecarReady = sidecarReady
        self.overrides = overrides
        self.makeInitialPrompt = makeInitialPrompt
        self.dictionarySubstitutions = dictionarySubstitutions
        self.recordOverride = recordOverride
        self.appendHistory = appendHistory
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
            await self.performInsert(pending)
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
}

extension DictationDriver {

    @MainActor
    fileprivate func resolve(_ pcm: PCMBuffer, mode: VoiceSessionMode, generation: Int) async {
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
    fileprivate func scanThenInsert(_ text: String, generation: Int) async {
        let parsed = TonePrefixParser().parse(text)
        let remainder = parsed.remainder
        let tone = parsed.preset ?? tonePreset()
        let focus = await inserter.resolveFocus()
        let override = focus.bundleID.flatMap { overrides()[$0] }
        let isTerminal = focus.bundleID.map(TerminalBundleAllowlist.contains) ?? false
        let plan = planner.plan(focus: focus, override: override, isTerminal: isTerminal)

        if isTerminal, let bundleID = focus.bundleID {
            let verdict = scanner.scan(
                remainder,
                context: ScanContext(
                    channel: .dictatedOneOff,
                    destinationBundleID: bundleID,
                    manifestID: nil))
            switch verdict {
            case .clean:
                break
            case .confirm:
                pendingInsert = PendingInsert(
                    text: remainder,
                    plan: plan,
                    tone: tone,
                    generation: generation,
                    focus: focus,
                    override: override)
                deliver(
                    .confirmBack(
                        ConfirmBackInfo(
                            transcript: remainder,
                            intent: remainder,
                            skillID: "dictation_insert",
                            riskTier: .alwaysConfirm)),
                    generation: generation)
                return
            case .hardBlock(let findings):
                deliver(
                    .hardBlocked(remainder, findings.first?.explanation ?? "Blocked"),
                    generation: generation)
                return
            }
        }

        await performInsert(
            PendingInsert(
                text: remainder,
                plan: plan,
                tone: tone,
                generation: generation,
                focus: focus,
                override: override))
    }

    @MainActor
    fileprivate func performInsert(_ pending: PendingInsert) async {
        let cleanup = await runDictationCleanup(raw: pending.text, tone: pending.tone)
        var insertion = await inserter.insert(cleanup.text, plan: pending.plan)
        guard generation == pending.generation else { return }

        if case .failed = insertion {
            await inserter.copyToClipboard(cleanup.text)
            insertion = .copiedToClipboard
        }

        let learnedBundleID = Self.learnedPasteOverrideBundleID(
            insertion: insertion, plan: pending.plan, focus: pending.focus)
        if let bundleID = learnedBundleID {
            recordOverride(bundleID, .paste)
        }

        let summary = Self.resultSummary(
            insertion: insertion,
            cleanupSummary: cleanup.resultSummary,
            accessibilityTrusted: pending.focus.accessibilityTrusted,
            override: pending.override)

        appendHistory(
            DictationHistoryEntry(
                transcript: pending.text,
                cleaned: cleanup.cleanedText,
                cleanupRan: cleanup.didRun,
                insertion: Self.historyInsertion(insertion),
                destinationBundleID: pending.focus.bundleID))

        deliver(.transcript(cleanup.text), generation: pending.generation)
        deliver(
            .result(VoiceSessionResult(transcript: cleanup.text, summary: summary)),
            generation: pending.generation)
    }

    private static func learnedPasteOverrideBundleID(
        insertion: InsertionResult,
        plan: InsertionPlan,
        focus: InsertionFocus
    ) -> String? {
        guard case .insertedViaPaste = insertion, plan == .axThenPaste else {
            return nil
        }
        return focus.bundleID
    }

    private static func resultSummary(
        insertion: InsertionResult,
        cleanupSummary: String,
        accessibilityTrusted: Bool,
        override: AppInsertionOverride?
    ) -> String {
        switch insertion {
        case .copiedToClipboard, .failed:
            return copiedToClipboardSummary
        case .insertedViaAX, .insertedViaPaste:
            if !accessibilityTrusted, override != .paste {
                return accessibilityDeniedSummary
            }
            return cleanupSummary
        }
    }

    private static func historyInsertion(_ result: InsertionResult) -> String {
        switch result {
        case .insertedViaAX: return "ax"
        case .insertedViaPaste: return "paste"
        case .copiedToClipboard: return "copied"
        case .failed: return "failed"
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
    fileprivate func deliver(_ update: VoiceSessionUpdate, generation: Int) {
        guard generation == self.generation else { return }
        onUpdate?(update)
    }

    fileprivate static func degraded(_ summary: String) -> VoiceSessionResult {
        VoiceSessionResult(transcript: "", summary: summary)
    }
}

private enum DictationCleanupOutcome {
    case cleaned(String)
    case skipped(String)
    case sidecarNotReady(String)
    case chatFailed(String)

    var text: String {
        switch self {
        case .cleaned(let text), .skipped(let text), .sidecarNotReady(let text),
            .chatFailed(let text):
            return text
        }
    }

    var resultSummary: String {
        switch self {
        case .cleaned(let text), .skipped(let text):
            return text
        case .sidecarNotReady:
            return DictationDriver.sidecarNotReadySummary
        case .chatFailed:
            return DictationDriver.cleanupFailedSummary
        }
    }

    var cleanedText: String? {
        if case .cleaned(let text) = self { return text }
        return nil
    }

    /// PRD: history records *whether cleanup ran*, not whether it succeeded.
    /// True only when the local LLM was actually called (`.cleaned` / `.chatFailed`).
    var didRun: Bool {
        switch self {
        case .cleaned, .chatFailed:
            return true
        case .skipped, .sidecarNotReady:
            return false
        }
    }
}

private let dictationCleanupSampling = SamplingParams(
    temperature: 0.2, topP: 1.0, maxTokens: 1024, topLogprobs: 0)

extension DictationDriver {
    fileprivate func runDictationCleanup(raw: String, tone: TonePreset) async -> DictationCleanupOutcome {
        guard cleanupEnabled() else {
            return .skipped(raw)
        }
        guard await sidecarReady() else {
            return .sidecarNotReady(raw)
        }

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
                tone: tone,
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
}
