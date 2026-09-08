import AideCore
import Foundation
import SpeechToText

/// Dictation-mode `VoiceSessionDriver`: capture → transcribe → Pre-Gate → insert
/// at the caret (plans/P5a-dictation-core.md Phase 1). Overlay/coordinator stay
/// unchanged; the mux swaps this in for `STTVoiceSessionDriver` on `.dictation`.
///
/// Depends only on `STTEngine`, `AudioCaptureBuffer`, `SegmentPreGate`, and
/// `TextInserting` — tests inject mocks; `App/TextInserterLive.swift` is the
/// AppKit shell.
public final class DictationDriver: VoiceSessionDriver {

    public var onUpdate: ((VoiceSessionUpdate) -> Void)?

    public static let reAskSummary = "I didn't catch that — try again."
    public static let modelNotReadySummary = "Speech model isn't ready yet."
    public static let microphoneUnavailableSummary = "Couldn't access the microphone."

    private let engine: any STTEngine
    private let capture: any AudioCaptureBuffer
    private let preGate: SegmentPreGate
    private let inserter: any TextInserting
    private let planner = InsertionPlanner()
    private let overrides: @Sendable () -> [String: AppInsertionOverride]
    private let makeInitialPrompt: @Sendable () async -> String?
    private let dictionarySubstitutions: @Sendable () async -> String

    private var generation = 0
    private var activeMode: VoiceSessionMode = .dictation
    private var captureTask: Task<Bool, Never>?

    public init(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate,
        inserter: any TextInserting,
        overrides: @escaping @Sendable () -> [String: AppInsertionOverride] = { [:] },
        makeInitialPrompt: @escaping @Sendable () async -> String? = { nil },
        dictionarySubstitutions: @escaping @Sendable () async -> String = { "" }
    ) {
        self.engine = engine
        self.capture = capture
        self.preGate = preGate
        self.inserter = inserter
        self.overrides = overrides
        self.makeInitialPrompt = makeInitialPrompt
        self.dictionarySubstitutions = dictionarySubstitutions
    }

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
        let capture = self.capture
        let started = captureTask
        Task {
            _ = await started?.value
            await capture.discard()
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
                await insertAndDeliver(text, generation: generation)
            case .fail:
                deliver(.result(Self.degraded(Self.reAskSummary)), generation: generation)
            }
        } catch {
            deliver(.result(Self.degraded(Self.modelNotReadySummary)), generation: generation)
        }
    }

    @MainActor
    private func insertAndDeliver(_ text: String, generation: Int) async {
        let focus = await inserter.resolveFocus()
        let override = focus.bundleID.flatMap { overrides()[$0] }
        let plan = planner.plan(focus: focus, override: override, isTerminal: false)
        let insertion = await inserter.insert(text, plan: plan)
        guard self.generation == generation else { return }

        deliver(.transcript(text), generation: generation)
        switch insertion {
        case .insertedViaAX, .insertedViaPaste, .copiedToClipboard:
            deliver(.result(VoiceSessionResult(transcript: text, summary: text)), generation: generation)
        case .failed(let reason):
            deliver(.result(VoiceSessionResult(transcript: text, summary: reason)), generation: generation)
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
