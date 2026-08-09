import XCTest

@testable import SpeechToText

/// `PCMRingBuffer` is the **pure** accounting core behind the `AudioCaptureBuffer`
/// contract (docs/05-lld.md §3.2) — capacity, wraparound, append→finalize order, and
/// sample-rate/frame bookkeeping — unit-tested headlessly with no mic (specs/P2a Phase 3;
/// the `DangerousCommandScanner` test-first pattern). The effectful AVAudioEngine tap
/// (`AudioCapture`, App/) stays out of this suite.
final class PCMRingBufferTests: XCTestCase {

    // MARK: - Append → finalize: count + order

    func testAppendThenFinalizeReturnsAllSamplesInOrder() async {
        let buffer = PCMRingBuffer(sampleRate: 16_000, capacitySamples: 10)
        try? await buffer.start()

        await buffer.append(PCMBuffer(samples: [1, 2, 3], sampleRate: 16_000))
        await buffer.append(PCMBuffer(samples: [4, 5], sampleRate: 16_000))

        let utterance = await buffer.finalize()
        XCTAssertEqual(utterance.samples, [1, 2, 3, 4, 5])
        XCTAssertEqual(utterance.sampleRate, 16_000)
    }

    func testBufferedSampleCountTracksAppends() async {
        let buffer = PCMRingBuffer(sampleRate: 16_000, capacitySamples: 10)
        try? await buffer.start()

        await buffer.append(PCMBuffer(samples: [1, 2, 3], sampleRate: 16_000))
        var count = await buffer.bufferedSampleCount
        XCTAssertEqual(count, 3)

        await buffer.append(PCMBuffer(samples: [4, 5], sampleRate: 16_000))
        count = await buffer.bufferedSampleCount
        XCTAssertEqual(count, 5)
    }

    // MARK: - Capacity + wraparound

    func testWraparoundKeepsMostRecentSamplesWhenOverCapacity() async {
        let buffer = PCMRingBuffer(sampleRate: 16_000, capacitySamples: 4)
        try? await buffer.start()

        await buffer.append(PCMBuffer(samples: [1, 2, 3], sampleRate: 16_000))
        await buffer.append(PCMBuffer(samples: [4, 5, 6], sampleRate: 16_000))  // 6 > 4

        let count = await buffer.bufferedSampleCount
        XCTAssertEqual(count, 4, "count is capped at capacity")
        let isFull = await buffer.isAtCapacity
        XCTAssertTrue(isFull)

        let utterance = await buffer.finalize()
        XCTAssertEqual(utterance.samples, [3, 4, 5, 6], "oldest samples evicted, order preserved")
    }

    func testExactlyAtCapacityRetainsEverythingInOrder() async {
        let buffer = PCMRingBuffer(sampleRate: 16_000, capacitySamples: 3)
        try? await buffer.start()

        await buffer.append(PCMBuffer(samples: [7, 8, 9], sampleRate: 16_000))

        let utterance = await buffer.finalize()
        XCTAssertEqual(utterance.samples, [7, 8, 9])
    }

    func testWraparoundAcrossASingleOversizedAppend() async {
        let buffer = PCMRingBuffer(sampleRate: 16_000, capacitySamples: 3)
        try? await buffer.start()

        await buffer.append(PCMBuffer(samples: [1, 2, 3, 4, 5], sampleRate: 16_000))  // one big chunk

        let utterance = await buffer.finalize()
        XCTAssertEqual(utterance.samples, [3, 4, 5], "keeps the last `capacity` samples")
    }

    // MARK: - discard clears

    func testDiscardClearsBuffer() async {
        let buffer = PCMRingBuffer(sampleRate: 16_000, capacitySamples: 10)
        try? await buffer.start()
        await buffer.append(PCMBuffer(samples: [1, 2, 3], sampleRate: 16_000))

        await buffer.discard()

        let count = await buffer.bufferedSampleCount
        XCTAssertEqual(count, 0)
        let utterance = await buffer.finalize()
        XCTAssertTrue(utterance.samples.isEmpty, "a discarded capture yields no utterance")
    }

    // MARK: - start / finalize reset (back-to-back captures don't bleed)

    func testStartResetsPreviousContents() async {
        let buffer = PCMRingBuffer(sampleRate: 16_000, capacitySamples: 10)
        try? await buffer.start()
        await buffer.append(PCMBuffer(samples: [1, 2, 3], sampleRate: 16_000))

        try? await buffer.start()  // a fresh capture

        let count = await buffer.bufferedSampleCount
        XCTAssertEqual(count, 0)
        let utterance = await buffer.finalize()
        XCTAssertTrue(utterance.samples.isEmpty)
    }

    func testFinalizeResetsSoTheNextCaptureStartsEmpty() async {
        let buffer = PCMRingBuffer(sampleRate: 16_000, capacitySamples: 10)
        try? await buffer.start()
        await buffer.append(PCMBuffer(samples: [1, 2], sampleRate: 16_000))
        _ = await buffer.finalize()

        let secondFinalize = await buffer.finalize()
        XCTAssertTrue(secondFinalize.samples.isEmpty, "finalize resets; a second finalize is empty")

        try? await buffer.start()
        await buffer.append(PCMBuffer(samples: [9], sampleRate: 16_000))
        let third = await buffer.finalize()
        XCTAssertEqual(third.samples, [9], "the buffer is reusable across captures")
    }

    // MARK: - Sample-rate / frame bookkeeping

    func testFinalizeCarriesTheConfiguredSampleRate() async {
        let buffer = PCMRingBuffer(sampleRate: PCMBuffer.whisperSampleRate, capacitySamples: 8)
        try? await buffer.start()
        await buffer.append(PCMBuffer(samples: [0.1, 0.2], sampleRate: PCMBuffer.whisperSampleRate))

        let utterance = await buffer.finalize()
        XCTAssertEqual(utterance.sampleRate, PCMBuffer.whisperSampleRate)
    }

    func testAppendIgnoresFramesAtAMismatchedSampleRate() async {
        let buffer = PCMRingBuffer(sampleRate: 16_000, capacitySamples: 10)
        try? await buffer.start()

        await buffer.append(PCMBuffer(samples: [1, 2], sampleRate: 48_000))  // wrong rate — dropped
        var count = await buffer.bufferedSampleCount
        XCTAssertEqual(count, 0, "a mismatched-rate append is a no-op, never silent corruption")

        await buffer.append(PCMBuffer(samples: [3, 4], sampleRate: 16_000))  // matching — kept
        count = await buffer.bufferedSampleCount
        XCTAssertEqual(count, 2)
        let utterance = await buffer.finalize()
        XCTAssertEqual(utterance.samples, [3, 4])
    }

    func testDurationInitDerivesCapacityFromSampleRate() async {
        // 16 kHz × 0.5 s = 8000 samples of capacity.
        let buffer = PCMRingBuffer(sampleRate: 16_000, maxDurationSeconds: 0.5)
        let capacity = await buffer.capacitySamples
        XCTAssertEqual(capacity, 8_000)
    }

    func testBufferedDurationSecondsReflectsSampleCount() async {
        let buffer = PCMRingBuffer(sampleRate: 16_000, capacitySamples: 16_000)
        try? await buffer.start()
        await buffer.append(PCMBuffer(samples: Array(repeating: 0, count: 8_000), sampleRate: 16_000))

        let seconds = await buffer.bufferedDurationSeconds
        XCTAssertEqual(seconds, 0.5, accuracy: 1e-9)
    }
}
