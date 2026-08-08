import Foundation

/// A finished mono PCM utterance handed to the `STTEngine` for batch decode
/// (docs/05-lld.md §3.2). v1 is batch-on-release; Phase 3's `PCMRingBuffer` /
/// `AudioCaptureBuffer` produces one of these on hotkey release. Samples are
/// normalized `Float` in `[-1, 1]` at `sampleRate` Hz, which is what whisper.cpp's
/// `whisper_full` expects (16 kHz mono).
public struct PCMBuffer: Equatable, Sendable {
    /// Normalized mono samples in `[-1, 1]`.
    public let samples: [Float]
    /// Sample rate in Hz. Whisper models are trained at `whisperSampleRate`.
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// The sample rate whisper.cpp expects (16 kHz).
    public static let whisperSampleRate = 16_000
}
