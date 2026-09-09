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
/// The capture → transcribe → Pre-Gate orchestration itself lives in
/// `SpeechToText.CaptureTranscribeGate` (P5a extraction — shared with
/// `Dictation.DictationDriver`, whose divergent tail continues into tone cleanup /
/// terminal scan / insert instead of the plain transcript-then-result below). It
/// lives in `SpeechToText` rather than here so both driver's pillars depend on it
/// without depending on each other's concrete module. This driver is now just that
/// shared front half plus the two-line Pre-Gate-pass tail.
public final class STTVoiceSessionDriver: VoiceSessionDriver {

    /// Delivered on the main actor. `VoiceSessionCoordinator` sets this at construction.
    public var onUpdate: ((VoiceSessionUpdate) -> Void)? {
        get { gate.onUpdate }
        set { gate.onUpdate = newValue }
    }

    private let gate: CaptureTranscribeGate

    // MARK: - Re-ask / degraded copy (single source; asserted by tests, never re-typed)
    //
    // Re-exported from `CaptureTranscribeGate` — see there for what each summary means
    // and when it's shown — so existing call sites (`STTVoiceSessionDriver.reAskSummary`
    // etc., in this module and in `STTVoiceSessionDriverTests`) keep resolving unchanged.

    public static let reAskSummary = CaptureTranscribeGate.reAskSummary
    public static let modelNotReadySummary = CaptureTranscribeGate.modelNotReadySummary
    public static let microphoneUnavailableSummary = CaptureTranscribeGate.microphoneUnavailableSummary

    public init(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate
    ) {
        self.gate = CaptureTranscribeGate(engine: engine, capture: capture, preGate: preGate)
        self.gate.onPass = { [weak self] text, generation, _ in
            guard let self else { return }
            await self.gate.deliver(.transcript(text), generation: generation)
            await self.gate.deliver(
                .result(VoiceSessionResult(transcript: text, summary: text)), generation: generation)
        }
    }

    // MARK: - VoiceSessionDriver

    /// Push-to-talk down: open the mic immediately and warm the model in parallel.
    public func begin(mode: VoiceSessionMode) {
        gate.begin(mode: mode)
    }

    /// Push-to-talk up: finalize the capture, decode it, Pre-Gate it, and deliver the
    /// result — `.transcript` then a placeholder `.result` on pass, or the re-ask on fail.
    public func end() {
        gate.end()
    }

    /// A newer press interrupted this session before it resolved: invalidate it (so any
    /// in-flight update is dropped) and tear the capture down without producing a result.
    public func cancel() {
        gate.cancel()
    }
}
