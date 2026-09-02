import AideCore
import CommandDispatcher
import CommandRouter
import Foundation
import LLMRuntime
import SkillManifest
import SkillRegistry
import SpeechToText

/// Command Mode `VoiceSessionDriver`: capture → STT → Pre-Gate → Route → Dispatch → Overlay.
///
/// Dictation stays on ``STTVoiceSessionDriver``; this conformer is the Command Mode
/// pipeline (plan Phase 7). Same generation-guard / main-actor `onUpdate` idiom as
/// the STT driver so `VoiceSessionCoordinator` needs no change.
///
/// Depends only on protocols (`STTEngine`, `AudioCaptureBuffer`, `Routing`,
/// `Dispatching`, `SkillRegistering`) — never `InferenceClient`, `WhisperSTTEngine`,
/// or AppKit.
public final class CommandModeDriver: VoiceSessionDriver {

    public var onUpdate: ((VoiceSessionUpdate) -> Void)?

    private let engine: any STTEngine
    private let capture: any AudioCaptureBuffer
    private let preGate: SegmentPreGate
    private let router: any Routing
    private let dispatcher: any Dispatching
    private let registry: any SkillRegistering
    private let logger: CalibrationLogger
    private let resolveEndpoint: @Sendable () async throws -> LLMEndpoint

    private var generation = 0
    private var activeMode: VoiceSessionMode = .command
    private var captureTask: Task<Bool, Never>?

    /// Honest re-ask on Pre-Gate `fail`. Same copy as `STTVoiceSessionDriver`.
    public static let reAskSummary = "I didn't catch that — try again."
    /// Whisper model absent/corrupt. Same copy as `STTVoiceSessionDriver`.
    public static let modelNotReadySummary = "Speech model isn't ready yet."
    /// Microphone could not be opened. Same copy as `STTVoiceSessionDriver`.
    public static let microphoneUnavailableSummary = "Couldn't access the microphone."

    public init(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate,
        router: any Routing,
        dispatcher: any Dispatching,
        registry: any SkillRegistering,
        logger: CalibrationLogger,
        resolveEndpoint: @escaping @Sendable () async throws -> LLMEndpoint
    ) {
        self.engine = engine
        self.capture = capture
        self.preGate = preGate
        self.router = router
        self.dispatcher = dispatcher
        self.registry = registry
        self.logger = logger
        self.resolveEndpoint = resolveEndpoint
    }

    /// Convenience for tests and other callers with a fixed endpoint.
    public convenience init(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate,
        router: any Routing,
        dispatcher: any Dispatching,
        registry: any SkillRegistering,
        logger: CalibrationLogger,
        endpoint: LLMEndpoint
    ) {
        self.init(
            engine: engine,
            capture: capture,
            preGate: preGate,
            router: router,
            dispatcher: dispatcher,
            registry: registry,
            logger: logger,
            resolveEndpoint: { endpoint }
        )
    }

    // MARK: - VoiceSessionDriver

    public func begin(mode: VoiceSessionMode) {
        generation &+= 1
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
                guard self.generation == generation else { return }
                self.deliver(
                    .result(Self.degraded(Self.microphoneUnavailableSummary)), generation: generation)
                await self.log(sttPregate: "fail", startedAt: Date())
                return
            }

            let pcm = await capture.finalize()
            guard self.generation == generation else { return }
            await self.resolve(pcm, mode: mode, generation: generation)
        }
    }

    public func cancel() {
        generation &+= 1
        let capture = self.capture
        let started = captureTask
        Task {
            _ = await started?.value
            await capture.discard()
        }
    }

    // MARK: - Decode + route + dispatch

    @MainActor
    private func resolve(_ pcm: PCMBuffer, mode: VoiceSessionMode, generation: Int) async {
        let startedAt = Date()
        do {
            try await engine.ensureLoaded()
            let transcription = try await engine.transcribe(
                Self.peakNormalize(pcm), language: .auto, initialPrompt: nil)
            guard self.generation == generation else { return }

            switch preGate.evaluate(transcription, mode: mode) {
            case .pass(let text, _):
                deliver(.transcript(text), generation: generation)
                await routeAndDispatch(
                    text: text, transcription: transcription, startedAt: startedAt,
                    generation: generation)
            case .fail:
                deliver(.result(Self.degraded(Self.reAskSummary)), generation: generation)
                await log(transcription: transcription, sttPregate: "fail", startedAt: startedAt)
            }
        } catch {
            guard self.generation == generation else { return }
            deliver(.result(Self.degraded(Self.modelNotReadySummary)), generation: generation)
            await log(sttPregate: "fail", startedAt: startedAt)
        }
    }

    @MainActor
    private func routeAndDispatch(
        text: String,
        transcription: Transcription,
        startedAt: Date,
        generation: Int
    ) async {
        do {
            let endpoint = try await resolveEndpoint()
            let intent = try await router.route(
                transcript: text,
                whisperAvgLogprob: transcription.utteranceAvgLogprob,
                endpoint: endpoint)
            guard self.generation == generation else { return }

            let outcome = await dispatcher.dispatch(
                intent, whisperAvgLogprob: transcription.utteranceAvgLogprob)
            guard self.generation == generation else { return }

            deliver(
                .result(VoiceSessionResult(transcript: text, summary: Self.summary(for: outcome))),
                generation: generation)
            await log(
                transcription: transcription, intent: intent, outcome: outcome, sttPregate: "pass",
                startedAt: startedAt)
        } catch {
            guard self.generation == generation else { return }
            deliver(
                .result(VoiceSessionResult(transcript: text, summary: error.localizedDescription)),
                generation: generation)
            await log(transcription: transcription, sttPregate: "pass", startedAt: startedAt)
        }
    }

    @MainActor
    private func deliver(_ update: VoiceSessionUpdate, generation: Int) {
        guard generation == self.generation else { return }
        onUpdate?(update)
    }

    private static func degraded(_ summary: String) -> VoiceSessionResult {
        VoiceSessionResult(transcript: "", summary: summary)
    }

    private static func summary(for outcome: DispatchOutcome) -> String {
        switch outcome {
        case .executed(let result):
            return result.summary
        case .promptedBack(let suggestion):
            return suggestion ?? ConfidenceGate.promptBackSuggestion
        case .confirmBack:
            return ConfidenceGate.confirmBackPrompt
        case .hardBlocked(let reason):
            return reason
        case .failed(let error):
            return error
        }
    }

    // MARK: - Calibration

    private func log(
        transcription: Transcription? = nil,
        intent: RoutedIntent? = nil,
        outcome: DispatchOutcome? = nil,
        sttPregate: String,
        startedAt: Date
    ) async {
        let skillID = intent?.decision.skillID
        let manifest: Manifest? = if let skillID { await registry.manifest(for: skillID) } else { nil }
        let paramValidation: String? =
            if let intent, let skillID {
                switch await registry.validate(parameters: intent.decision.parameters, for: skillID) {
                case .success: "pass"
                case .failure: "fail"
                }
            } else {
                nil
            }
        let latencyMs = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
        let record = CalibrationRecord(
            ts: Date(),
            whisperAvgLogprob: transcription?.utteranceAvgLogprob,
            whisperMinSegmentLogprob: transcription?.segments.map(\.avgLogprob).min(),
            sttPregate: sttPregate,
            chosenSkillID: skillID,
            idSelectingTokenCount: intent?.confidence.idSelectingTokenCount,
            routingLogprobSum: intent?.confidence.logprobSum,
            routingLogprobMean: intent?.confidence.logprobMean,
            paramValidation: paramValidation,
            riskTier: manifest?.riskTier,
            scannerVerdict: outcome.flatMap { Self.scannerVerdict(skillID: skillID, outcome: $0) },
            actionTaken: outcome.map(Self.actionTaken) ?? "prompted_back",
            userOutcome: nil,
            latencyMs: latencyMs
        )
        try? logger.append(record)
    }

    private static func actionTaken(_ outcome: DispatchOutcome) -> String {
        switch outcome {
        case .executed: "executed"
        case .promptedBack: "prompted_back"
        case .confirmBack: "confirm_back"
        case .hardBlocked: "hard_block"
        case .failed: "prompted_back"
        }
    }

    private static func scannerVerdict(skillID: String?, outcome: DispatchOutcome) -> String? {
        guard let skillID, ExecutableCommandRenderer.isExecutable(skillID) else { return nil }
        switch outcome {
        case .hardBlocked:
            return "hard_block"
        case .confirmBack(let prompt):
            if let findings = prompt.findings, !findings.isEmpty { return "confirm" }
            return "clean"
        case .executed, .promptedBack, .failed:
            return "clean"
        }
    }

    // MARK: - PCM (same policy as STTVoiceSessionDriver; do not share a module edge)

    private static func peakNormalize(_ pcm: PCMBuffer) -> PCMBuffer {
        let targetPeak: Float = 0.9
        let maxAmp = pcm.samples.reduce(Float(0)) { max($0, abs($1)) }
        guard maxAmp > 0.001 else { return pcm }
        let gain = min(targetPeak / maxAmp, 20.0)
        guard gain > 1.05 else { return pcm }
        return PCMBuffer(samples: pcm.samples.map { $0 * gain }, sampleRate: pcm.sampleRate)
    }
}
