import AideCore
import Foundation
import SpeechToText

/// The **real** conformer of the `AideCore.VoiceSessionDriver` seam (specs/P2a
/// §"Effectful shells"; plan Phase 3) — the point at which P1's mock is finally
/// replaced by live local speech-to-text. On a push-to-talk hold it drives
/// `AudioCapture` → `WhisperSTTEngine` → `SegmentPreGate` and reports the outcome through
/// `onUpdate`, so `VoiceSessionCoordinator` and the Overlay it inherited from P1 render a
/// real transcript with **no** rewiring (User Story 22 — the seam paying off).
///
/// **Testable orchestration:** the driver depends only on the `STTEngine` and
/// `AudioCaptureBuffer` *protocols* (plus the pure `SegmentPreGate`) — never on the
/// concrete native engine or the AVAudioEngine tap. Production injects `WhisperSTTEngine`
/// + `AudioCapture`; the headless suite injects `MockSTTEngine` + a fake capture, so the
/// pass / re-ask / cancel behaviour is unit-tested with no mic and no native binary.
///
/// **Concurrency (LLD §10):** `onUpdate` is delivered on the **main actor** (the seam
/// contract). `begin`/`end`/`cancel` are called on the main actor by the coordinator;
/// this driver mirrors `MockVoiceSessionDriver`'s idiom — plain class, main-affine
/// coordination state, generation-guarded so a superseded session's late update is
/// dropped — while the heavy decode runs off-main on the injected engine actor.
public final class STTVoiceSessionDriver: VoiceSessionDriver {

    /// Delivered on the main actor. `VoiceSessionCoordinator` sets this at construction.
    public var onUpdate: ((VoiceSessionUpdate) -> Void)?

    private let engine: any STTEngine
    private let capture: any AudioCaptureBuffer
    private let preGate: SegmentPreGate

    /// Bumped by `begin`/`cancel` so a late update from a superseded/cancelled session
    /// is dropped — the driver-level half of "a new press cancels the prior" (LLD §10),
    /// mirroring `MockVoiceSessionDriver.generation`. Main-actor-affine.
    private var generation = 0

    /// The mode of the in-flight session, captured on `begin` and read on `end` (both on
    /// the main actor) so the Pre-Gate runs strict/command vs lenient/dictation correctly.
    private var activeMode: VoiceSessionMode = .command

    /// The mic-open task started on `begin`; `end`/`cancel` await it so `finalize`/
    /// `discard` never race ahead of `start` (`true` = the input node opened).
    private var captureTask: Task<Bool, Never>?

    // MARK: - Re-ask / degraded copy (single source; asserted by tests, never re-typed)

    /// The honest "I didn't catch that" re-ask surfaced on any Pre-Gate `fail`
    /// (silence / noise / repetition / low confidence). Delivered through the existing
    /// `.result` seam so neither `VoiceSessionCoordinator` nor the Overlay changes.
    public static let reAskSummary = "I didn't catch that — try again."

    /// Shown when the Whisper model can't be loaded (absent/corrupt). Full model-not-ready
    /// UX is Phase 5; here it fails safe with a clear, non-crashing state (User Story 19).
    public static let modelNotReadySummary = "Speech model isn't ready yet."

    /// Shown when the microphone couldn't be opened (permission not granted, no input
    /// device). Graceful degradation — the app stays alive and says why (User Story 19).
    public static let microphoneUnavailableSummary = "Couldn't access the microphone."

    public init(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate
    ) {
        self.engine = engine
        self.capture = capture
        self.preGate = preGate
    }

    // MARK: - VoiceSessionDriver

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
    /// result — `.transcript` then a placeholder `.result` on pass, or the re-ask on fail.
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
            guard self.generation == generation else { return }
            await self.resolve(pcm, mode: mode, generation: generation)
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
    private func resolve(_ pcm: PCMBuffer, mode: VoiceSessionMode, generation: Int) async {
        do {
            try await engine.ensureLoaded()
            let transcription = try await engine.transcribe(pcm, language: .auto, initialPrompt: nil)
            guard self.generation == generation else { return }

            switch preGate.evaluate(transcription, mode: mode) {
            case .pass(let text, _):
                // The recognized words appear first (rendered while `.processing`), then a
                // placeholder `.result` — routing (a real summary) arrives in P4.
                deliver(.transcript(text), generation: generation)
                deliver(.result(VoiceSessionResult(transcript: text, summary: text)), generation: generation)
            case .fail:
                deliver(.result(Self.degraded(Self.reAskSummary)), generation: generation)
            }
        } catch {
            // Model absent/corrupt or decode failure — surface a clear state, never crash.
            deliver(.result(Self.degraded(Self.modelNotReadySummary)), generation: generation)
        }
    }

    /// Deliver one update on the main actor, unless a newer session has superseded this
    /// one (the generation guard — the same drop-late-updates rule as the mock).
    @MainActor
    private func deliver(_ update: VoiceSessionUpdate, generation: Int) {
        guard generation == self.generation else { return }
        onUpdate?(update)
    }

    /// A degraded/re-ask outcome carried over the existing `.result` seam: no transcript,
    /// just the honest human-readable summary the Overlay already renders.
    private static func degraded(_ summary: String) -> VoiceSessionResult {
        VoiceSessionResult(transcript: "", summary: summary)
    }
}
