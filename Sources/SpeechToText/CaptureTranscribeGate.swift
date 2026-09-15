import AideCore
import Foundation

/// The shared capture → transcribe → Pre-Gate front half of every real
/// `VoiceSessionDriver` (specs/P2a §"Effectful shells"; P5a extraction of the
/// duplication between `STTVoiceSessionDriver` and `Dictation.DictationDriver`).
///
/// Owns the mic lifecycle (`begin`/`end`/`cancel`), the generation counter that
/// invalidates a superseded/cancelled session's late updates, peak normalization,
/// and the decode → Pre-Gate pipeline. On Pre-Gate **pass** it calls `onPass` and
/// stops — it knows nothing about what a driver does with the passing text (plain
/// transcript-then-result for `STTVoiceSessionDriver`; tone cleanup → terminal scan
/// → insert for `DictationDriver`). On **fail** — Pre-Gate rejection, a model that
/// won't load, or a mic that won't open — it delivers the matching degraded
/// `.result` itself, since that behaviour is identical for every driver.
///
/// Composition, not inheritance (this codebase has no shared base-class pattern):
/// each driver owns one `CaptureTranscribeGate` instance and configures `onPass`
/// (and, for `DictationDriver`, `makeInitialPrompt`) to supply its divergent tail.
///
/// **Testable orchestration:** depends only on the `STTEngine`/`AudioCaptureBuffer`
/// *protocols* (plus the pure `SegmentPreGate`) — never a concrete native engine or
/// the AVAudioEngine tap.
///
/// **Concurrency (LLD §10):** mirrors `MockVoiceSessionDriver`'s idiom — plain
/// class, main-affine coordination state, generation-guarded so a superseded
/// session's late update is dropped — while the heavy decode runs off-main on the
/// injected engine actor. `begin`/`end`/`cancel` are called on the main actor by
/// the owning driver; `onUpdate` is delivered on the main actor.
public final class CaptureTranscribeGate {

    /// Delivered on the main actor. The owning driver's own `onUpdate` forwards
    /// here (or is this property directly, for a driver with no divergent tail).
    public var onUpdate: ((VoiceSessionUpdate) -> Void)?

    /// Called on Pre-Gate **pass**, on the main actor, with the already
    /// generation-guarded transcript and this pass's `Timings`. Configured by the
    /// owning driver after construction — mirrors `onUpdate`'s configure-after-init
    /// idiom, and lets a driver capture `self` weakly without the init-order problem
    /// a stored closure captured at construction time would create.
    public var onPass: ((String, Int, Timings) async -> Void)?

    /// Per-stage latency of one capture → transcribe pass (P5a — dictation latency
    /// instrumentation), handed to `onPass` alongside the transcript. Milliseconds,
    /// measured with `ContinuousClock` (monotonic; never wall-clock `Date`).
    public struct Timings: Sendable {
        /// Duration of the captured audio itself — PCM sample count ÷ sample rate.
        public let audioMs: Int
        /// Time spent in `engine.ensureLoaded()` — near-zero when already warm
        /// (`ensureLoaded` returns immediately once the model context exists).
        public let modelLoadMs: Int
        /// Time spent in `engine.transcribe(...)`.
        public let sttMs: Int
        /// The instant audio capture finished (mic finalized), before decode
        /// began — the reference point an owning driver's own `total_ms` should
        /// measure against, since that's closest to what the user actually feels.
        public let captureEndedAt: ContinuousClock.Instant
    }

    // MARK: - Re-ask / degraded copy (single source; asserted by both driver's tests)

    /// The honest "I didn't catch that" re-ask surfaced on any Pre-Gate `fail`
    /// (silence / noise / repetition / low confidence). Delivered through the existing
    /// `.result` seam so neither `VoiceSessionCoordinator` nor the Overlay changes.
    public static let reAskSummary = "I didn't catch that — try again."

    /// Shown when the Whisper model can't be loaded (absent/corrupt). Fails safe
    /// with a clear, non-crashing state (User Story 19).
    public static let modelNotReadySummary = "Speech model isn't ready yet."

    /// Shown when the microphone couldn't be opened (permission not granted, no input
    /// device). Graceful degradation — the app stays alive and says why (User Story 19).
    public static let microphoneUnavailableSummary = "Couldn't access the microphone."

    private let engine: any STTEngine
    private let capture: any AudioCaptureBuffer
    private let preGate: SegmentPreGate

    /// P5b seam: lets `DictationDriver` bias the decode with dictionary/context text.
    /// `STTVoiceSessionDriver` leaves this at its default (`nil`).
    private let makeInitialPrompt: @Sendable () async -> String?

    /// Bumped by `begin`/`cancel` so a late update from a superseded/cancelled session
    /// is dropped — the driver-level half of "a new press cancels the prior" (LLD §10),
    /// mirroring `MockVoiceSessionDriver.generation`. Main-actor-affine. Exposed so an
    /// owning driver's own post-Pre-Gate work (cleanup, insertion, approve/reject) can
    /// re-check it before acting on a result that may have been superseded.
    public private(set) var generation = 0

    /// The mode of the in-flight session, captured on `begin` and read on `end` (both on
    /// the main actor) so the Pre-Gate runs strict/command vs lenient/dictation correctly.
    private var activeMode: VoiceSessionMode = .command

    /// The mic-open task started on `begin`; `end`/`cancel` await it so `finalize`/
    /// `discard` never race ahead of `start` (`true` = the input node opened).
    private var captureTask: Task<Bool, Never>?

    public init(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate,
        makeInitialPrompt: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.engine = engine
        self.capture = capture
        self.preGate = preGate
        self.makeInitialPrompt = makeInitialPrompt
    }

    // MARK: - Mic lifecycle

    /// Push-to-talk down: open the mic immediately and warm the model in parallel.
    public func begin(mode: VoiceSessionMode) {
        generation &+= 1
        activeMode = mode

        // Open the input node right away — never blocked behind a (slow) first model load.
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                try await self.capture.start()
                return true
            } catch {
                return false
            }
        }

        // Warm the Whisper context in parallel; kept warm across utterances thereafter.
        // Best-effort here — `end()` re-`ensureLoaded()`s authoritatively before decoding.
        Task { [engine] in try? await engine.ensureLoaded() }
    }

    /// Push-to-talk up: finalize the capture, decode it, Pre-Gate it, and deliver the
    /// result — `.transcript` then a placeholder `.result` on pass (via `onPass`), or
    /// the re-ask / degraded `.result` on fail.
    public func end() {
        let generation = self.generation
        let mode = activeMode
        let capture = self.capture
        let started = captureTask

        Task { @MainActor [weak self] in
            guard let self else { return }
            let didStart = await started?.value ?? true
            guard self.generation == generation else { return }  // cancelled/restarted meanwhile

            guard didStart else {
                await capture.discard()
                self.deliver(.result(Self.degraded(Self.microphoneUnavailableSummary)), generation: generation)
                return
            }

            let pcm = await capture.finalize()
            let captureEndedAt = ContinuousClock.now
            guard self.generation == generation else { return }
            await self.resolve(pcm, mode: mode, generation: generation, captureEndedAt: captureEndedAt)
        }
    }

    /// A newer press interrupted this session before it resolved: invalidate it (so any
    /// in-flight update is dropped) and tear the capture down without producing a result.
    public func cancel() {
        generation &+= 1
        let capture = self.capture
        let started = captureTask
        Task {
            _ = await started?.value  // let `start` settle so `discard` truly closes the mic
            await capture.discard()
        }
    }

    // MARK: - Decode + gate + deliver (main actor)

    @MainActor
    private func resolve(
        _ pcm: PCMBuffer, mode: VoiceSessionMode, generation: Int, captureEndedAt: ContinuousClock.Instant
    ) async {
        let audioMs = Self.durationMs(samples: pcm.samples.count, sampleRate: pcm.sampleRate)
        do {
            let loadStart = ContinuousClock.now
            try await engine.ensureLoaded()
            let modelLoadMs = Self.elapsedMs(since: loadStart)

            let normalized = Self.peakNormalize(pcm)
            let prompt = await makeInitialPrompt()

            let sttStart = ContinuousClock.now
            let transcription = try await engine.transcribe(
                normalized, language: .auto, initialPrompt: prompt)
            let sttMs = Self.elapsedMs(since: sttStart)
            guard self.generation == generation else { return }

            switch preGate.evaluate(transcription, mode: mode) {
            case .pass(let text, _):
                let timings = Timings(
                    audioMs: audioMs, modelLoadMs: modelLoadMs, sttMs: sttMs, captureEndedAt: captureEndedAt)
                await onPass?(text, generation, timings)
            case .fail:
                deliver(.result(Self.degraded(Self.reAskSummary)), generation: generation)
            }
        } catch {
            deliver(.result(Self.degraded(Self.modelNotReadySummary)), generation: generation)
        }
    }

    /// Elapsed time since `start`, in whole milliseconds.
    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        Self.durationMs(ContinuousClock.now - start)
    }

    /// `samples ÷ sampleRate`, in whole milliseconds. `0` for a degenerate
    /// (zero-rate) buffer rather than dividing by zero.
    private static func durationMs(samples: Int, sampleRate: Int) -> Int {
        guard sampleRate > 0 else { return 0 }
        return Int((Double(samples) / Double(sampleRate)) * 1000)
    }

    private static func durationMs(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int((Double(seconds) * 1000) + (Double(attoseconds) / 1e15))
    }

    /// Peak-normalize PCM so Whisper sees a consistent signal level regardless of
    /// hardware mic gain. Target peak is 0.9 (headroom against clipping). Only
    /// amplifies quiet audio — loud audio is returned unchanged. A near-silent buffer
    /// (maxAmp < 0.001) is also returned unchanged to avoid amplifying pure noise.
    /// Gain is capped at 20× to prevent extreme amplification of very quiet signals.
    private static func peakNormalize(_ pcm: PCMBuffer) -> PCMBuffer {
        let targetPeak: Float = 0.9
        let maxAmp = pcm.samples.reduce(Float(0)) { max($0, abs($1)) }
        guard maxAmp > 0.001 else { return pcm }
        let gain = min(targetPeak / maxAmp, 20.0)
        guard gain > 1.05 else { return pcm }
        return PCMBuffer(samples: pcm.samples.map { $0 * gain }, sampleRate: pcm.sampleRate)
    }

    /// Deliver one update on the main actor, unless a newer session has superseded this
    /// one (the generation guard — the same drop-late-updates rule as the mock). Public
    /// so an owning driver's own divergent tail (confirm-back, hard-block, the final
    /// insert result, …) delivers through the same guard.
    @MainActor
    public func deliver(_ update: VoiceSessionUpdate, generation: Int) {
        guard generation == self.generation else { return }
        onUpdate?(update)
    }

    /// A degraded/re-ask outcome carried over the existing `.result` seam: no transcript,
    /// just the honest human-readable summary the Overlay already renders.
    private static func degraded(_ summary: String) -> VoiceSessionResult {
        VoiceSessionResult(transcript: "", summary: summary)
    }
}
