import Foundation

/// The capture-buffer seam (docs/05-lld.md §3.2): the audio tap fills it while the
/// push-to-talk hotkey is held; `finalize()` hands back the completed utterance on
/// release (**batch-on-release** in v1 — the `append` / `finalize` shape is deliberately
/// streaming-ready so a later partial-decode mode is additive).
///
/// Two conformers sit behind this one contract:
/// - `PCMRingBuffer` — the **pure** accounting core (capacity, wraparound, order), unit-
///   tested headlessly with no hardware.
/// - `AudioCapture` (App/) — the **effectful** AVAudioEngine mic-tap shell that opens the
///   input node while held and feeds the frames through to a `PCMRingBuffer`.
///
/// `STTVoiceSessionDriver` depends only on this protocol, so it is exercised with a fake
/// capture in the headless suite and wired to the real mic in production — the P1
/// `CGEventTap` precedent (the OS-bound edge stays out of the fast unit gate).
///
/// An `Actor`: the tap callback runs on a realtime audio thread and must hop into the
/// buffer's isolation to `append`, never touching its storage concurrently (LLD §10).
public protocol AudioCaptureBuffer: Actor {
    /// Begin a fresh capture — resets any prior contents. In the mic shell this also
    /// opens the input node (the mic must be granted, §8); the pure buffer just clears.
    func start() async throws

    /// Append captured frames (mono PCM at the buffer's sample rate). Frames beyond the
    /// buffer's capacity evict the oldest (wraparound) so a held-forever hotkey can never
    /// grow memory without bound.
    func append(_ frames: PCMBuffer) async

    /// Close the capture and return the accumulated utterance (batch-on-release), then
    /// reset for the next one.
    func finalize() async -> PCMBuffer

    /// Abandon the capture and clear it without producing an utterance (a cancelled
    /// session — a new press interrupted this one, LLD §10).
    func discard() async
}
