import Foundation

/// The **pure** accounting core behind the `AudioCaptureBuffer` contract (docs/05-lld.md
/// §3.2) — a fixed-capacity circular buffer of mono `Float` samples. It is the deep
/// module the effectful `AudioCapture` mic-tap shell (App/) delegates its bookkeeping to,
/// so the capacity/wraparound/order logic is unit-tested headlessly with no hardware
/// (specs/P2a Phase 3; the `DangerousCommandScanner` pattern).
///
/// **Wraparound:** the buffer holds at most `capacitySamples`. Appending past capacity
/// overwrites the oldest samples, so a held-forever hotkey can never grow memory without
/// bound; `finalize()` always returns the retained samples in chronological order.
///
/// An `actor`: the mic tap runs off-main and hops in to `append` (LLD §10). For the pure
/// unit path there is no thread contention — the isolation just satisfies the contract.
public actor PCMRingBuffer: AudioCaptureBuffer {

    /// The mono sample rate this buffer accounts for (16 kHz for Whisper). Appended
    /// frames at any other rate are dropped rather than silently mixed (see `append`).
    public let sampleRate: Int

    /// The maximum number of samples retained; older samples are evicted past this.
    public let capacitySamples: Int

    /// The circular backing store (`capacitySamples` wide). `writeIndex` is the next
    /// write slot; `filled` is how many slots hold valid samples (≤ capacity).
    private var backing: [Float]
    private var writeIndex = 0
    private var filled = 0

    /// - Parameters:
    ///   - sampleRate: the mono rate frames must arrive at (default: Whisper's 16 kHz).
    ///   - capacitySamples: the retention cap in samples (must be ≥ 1).
    public init(sampleRate: Int = PCMBuffer.whisperSampleRate, capacitySamples: Int) {
        precondition(capacitySamples >= 1, "PCMRingBuffer needs a capacity of at least one sample")
        self.sampleRate = sampleRate
        self.capacitySamples = capacitySamples
        self.backing = [Float](repeating: 0, count: capacitySamples)
    }

    /// Capacity expressed as a maximum utterance duration — the ergonomic production init
    /// (`capacity = sampleRate × seconds`, floored to at least one sample).
    public init(sampleRate: Int = PCMBuffer.whisperSampleRate, maxDurationSeconds: Double) {
        let samples = Int((Double(sampleRate) * maxDurationSeconds).rounded())
        self.init(sampleRate: sampleRate, capacitySamples: max(1, samples))
    }

    // MARK: - Bookkeeping (read-only)

    /// How many valid samples are currently buffered (≤ `capacitySamples`).
    public var bufferedSampleCount: Int { filled }

    /// Whether the buffer has reached its retention cap (further appends now evict).
    public var isAtCapacity: Bool { filled == capacitySamples }

    /// The buffered audio's duration in seconds (`count / sampleRate`).
    public var bufferedDurationSeconds: Double { Double(filled) / Double(sampleRate) }

    // MARK: - AudioCaptureBuffer

    /// Begin a fresh capture: clear any prior contents. The pure buffer opens no hardware
    /// (the mic shell overrides this to also open the input node) and so never throws.
    public func start() async throws {
        reset()
    }

    /// Append `frames`, evicting the oldest samples once past capacity. Frames whose
    /// `sampleRate` does not match this buffer's are **dropped** — mixing rates would
    /// corrupt the utterance into garbage the Pre-Gate might pass, so it is refused here.
    public func append(_ frames: PCMBuffer) async {
        guard frames.sampleRate == sampleRate else { return }
        for sample in frames.samples {
            backing[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacitySamples
            if filled < capacitySamples { filled += 1 }
        }
    }

    /// Return the accumulated utterance (oldest → newest) and reset for the next capture.
    public func finalize() async -> PCMBuffer {
        let samples = orderedSamples()
        reset()
        return PCMBuffer(samples: samples, sampleRate: sampleRate)
    }

    /// Abandon the capture and clear it, producing no utterance.
    public func discard() async {
        reset()
    }

    // MARK: - Internals

    /// The buffered samples in chronological order. When `filled < capacity` the oldest
    /// sits at index 0; once wrapped, the oldest is at `writeIndex` (the next slot to be
    /// overwritten), so we read `filled` samples forward from there.
    private func orderedSamples() -> [Float] {
        guard filled > 0 else { return [] }
        let oldest = (writeIndex - filled + capacitySamples) % capacitySamples
        var out = [Float]()
        out.reserveCapacity(filled)
        for offset in 0..<filled {
            out.append(backing[(oldest + offset) % capacitySamples])
        }
        return out
    }

    private func reset() {
        writeIndex = 0
        filled = 0
    }
}
