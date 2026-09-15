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
/// Dictation stays on ``STTVoiceSessionDriver``. ``VoiceSessionCoordinator`` maps
/// `.confirmBack`, `.promptBack`, and `.hardBlocked` onto Overlay in addition to
/// `.transcript` / `.result`.
///
/// Depends only on protocols (`STTEngine`, `AudioCaptureBuffer`, `Routing`,
/// `Dispatching`, `SkillRegistering`) — never `InferenceClient`, `WhisperSTTEngine`,
/// or AppKit.
public final class CommandModeDriver: VoiceSessionDriver {

    public var onUpdate: ((VoiceSessionUpdate) -> Void)?

    let engine: any STTEngine
    let capture: any AudioCaptureBuffer
    let preGate: SegmentPreGate
    let router: any Routing
    let dispatcher: any Dispatching
    let registry: any SkillRegistering
    let logger: CalibrationLogger
    let makeInitialPrompt: @Sendable () async -> String?
    let resolveEndpoint: @Sendable () async throws -> LLMEndpoint

    var generation = 0
    var activeMode: VoiceSessionMode = .command
    var captureTask: Task<Bool, Never>?
    var pendingConfirm: PendingConfirm?

    struct PendingConfirm {
        var intent: RoutedIntent
        var text: String
        var transcription: Transcription
        var startedAt: Date
        var generation: Int
        var outcome: DispatchOutcome
    }

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
        makeInitialPrompt: @escaping @Sendable () async -> String?,
        resolveEndpoint: @escaping @Sendable () async throws -> LLMEndpoint
    ) {
        self.engine = engine
        self.capture = capture
        self.preGate = preGate
        self.router = router
        self.dispatcher = dispatcher
        self.registry = registry
        self.logger = logger
        self.makeInitialPrompt = makeInitialPrompt
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
        makeInitialPrompt: @escaping @Sendable () async -> String?,
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
            makeInitialPrompt: makeInitialPrompt,
            resolveEndpoint: { endpoint }
        )
    }

    public func begin(mode: VoiceSessionMode) {
        generation &+= 1
        activeMode = mode
        pendingConfirm = nil
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
        pendingConfirm = nil
        let capture = self.capture
        let started = captureTask
        Task {
            _ = await started?.value
            await capture.discard()
        }
    }

    public func approve() {
        guard let pending = pendingConfirm else { return }
        pendingConfirm = nil
        let generation = pending.generation
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            let outcome = await self.dispatcher.dispatchApproved(pending.intent)
            guard self.generation == generation else { return }
            self.deliver(
                .result(
                    VoiceSessionResult(
                        transcript: pending.text,
                        summary: Self.summary(for: outcome))),
                generation: generation)
            await self.log(
                transcription: pending.transcription,
                intent: pending.intent,
                outcome: outcome,
                sttPregate: "pass",
                startedAt: pending.startedAt,
                userOutcome: "accepted")
        }
    }

    public func reject() {
        guard let pending = pendingConfirm else { return }
        pendingConfirm = nil
        Task { [weak self] in
            await self?.log(
                transcription: pending.transcription,
                intent: pending.intent,
                outcome: pending.outcome,
                sttPregate: "pass",
                startedAt: pending.startedAt,
                userOutcome: "rejected")
        }
    }

    @MainActor
    func deliver(_ update: VoiceSessionUpdate, generation: Int) {
        guard generation == self.generation else { return }
        onUpdate?(update)
    }

    static func degraded(_ summary: String) -> VoiceSessionResult {
        VoiceSessionResult(transcript: "", summary: summary)
    }
}

/// Default `appCatalog` conformer for callers that don't bias transcription toward
/// installed-app names (e.g. existing test helpers). Always empty.
public struct EmptyInstalledApplicationCatalog: InstalledApplicationCatalog {
    public init() {}
    public func installedApplications() async -> [InstalledApplication] { [] }
}
