import AVFoundation
import SpeechToText
import os

/// Why the microphone couldn't be opened (surfaced to the driver as graceful degradation,
/// never a crash — specs/P2a Phase 3; User Story 19).
enum AudioCaptureError: Error {
    /// No usable input device / the input node reported a zero sample rate.
    case noInputAvailable
    /// Could not build the 16 kHz mono target format or a converter to it.
    case formatUnavailable
}

/// The effectful **AVAudioEngine mic-tap shell** (specs/P2a §"Effectful shells"; LLD
/// §3.2) — the OS-bound edge that turns held-hotkey speech into the mono 16 kHz PCM the
/// `WhisperSTTEngine` expects. It conforms to `AudioCaptureBuffer` and delegates all
/// buffer accounting to the pure, unit-tested `PCMRingBuffer`; this file adds only the
/// hardware: open the input node on `start()`, resample each tap buffer to 16 kHz mono,
/// and close it on `finalize()`/`discard()`.
///
/// **Mic hygiene (User Story 6):** the input node is opened only inside `start()` (the
/// push-to-talk hold) and torn down in `finalize()`/`discard()` (release / cancel) — the
/// mic is never hot otherwise. Like `HotkeyManager`'s `CGEventTap`, this shell is verified
/// by build + a manual mic test, not the headless unit gate (the tap runs on a realtime
/// audio thread and hops into this actor to `append`, LLD §10).
actor AudioCapture: AudioCaptureBuffer {

    private let engine = AVAudioEngine()
    private let ring: PCMRingBuffer
    private let logger = Logger(subsystem: "com.aide.Aide", category: "AudioCapture")

    /// Whether the input node is currently tapped/running — makes `start`/`stop`
    /// idempotent and guarantees the mic is closed at most once.
    private var isRunning = false

    /// - Parameter maxUtteranceSeconds: the ring buffer's retention cap; a held-forever
    ///   hotkey evicts the oldest audio rather than growing memory without bound.
    init(maxUtteranceSeconds: Double = 60) {
        self.ring = PCMRingBuffer(
            sampleRate: PCMBuffer.whisperSampleRate, maxDurationSeconds: maxUtteranceSeconds)
    }

    // MARK: - AudioCaptureBuffer

    /// Open the input node and start feeding resampled frames into the ring buffer.
    func start() async throws {
        try await ring.start()
        guard !isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputAvailable
        }
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(PCMBuffer.whisperSampleRate),
                channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            throw AudioCaptureError.formatUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let samples = AudioCapture.resample(buffer, using: converter, to: targetFormat)
            guard !samples.isEmpty else { return }
            Task { await self?.ingest(samples) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            logger.error("Failed to start audio engine: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        isRunning = true
    }

    func append(_ frames: PCMBuffer) async {
        await ring.append(frames)
    }

    /// Close the mic and return the accumulated utterance (batch-on-release).
    func finalize() async -> PCMBuffer {
        stopEngine()
        return await ring.finalize()
    }

    /// Close the mic and drop the capture (a cancelled session).
    func discard() async {
        stopEngine()
        await ring.discard()
    }

    // MARK: - Internals

    /// Append resampled frames arriving from the tap thread.
    private func ingest(_ samples: [Float]) async {
        await ring.append(PCMBuffer(samples: samples, sampleRate: PCMBuffer.whisperSampleRate))
    }

    private func stopEngine() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Resample one tap buffer (hardware rate, possibly multi-channel) to 16 kHz mono
    /// `Float` samples. Runs on the realtime audio thread — the single owner of
    /// `converter` — so its non-`Sendable` use is confined to that one thread.
    private static func resample(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to target: AVAudioFormat
    ) -> [Float] {
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 1)
        guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return []
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
