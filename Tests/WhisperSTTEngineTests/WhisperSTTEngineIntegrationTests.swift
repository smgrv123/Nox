import AideCore
import SpeechToText
import XCTest

@testable import WhisperSTTEngine

/// The opt-in **headless integration check** for the real whisper.cpp decode (specs/P2a
/// §"Testing Decisions"; plan Phase 1): feed the committed sample WAV through the real
/// `WhisperSTTEngine` and assert the transcript contains the expected words with the
/// per-segment probability fields populated. This is the tracer bullet that proves the
/// pinned xcframework links and decodes in-process.
///
/// It is **excluded from the fast unit gate**: it runs only when `AIDE_RUN_STT_INTEGRATION=1`
/// and a model has been placed at `~/Library/Application Support/Aide/models/ggml-base.en.bin`.
/// Absent either, it `XCTSkip`s, so `just test` on a machine without the model stays green.
///
/// Run it with:
///     AIDE_RUN_STT_INTEGRATION=1 swift test --filter WhisperSTTEngineIntegrationTests
final class WhisperSTTEngineIntegrationTests: XCTestCase {

    /// The manually-placed model path (Phase 1); Phase 5's provisioning retires this.
    private var modelURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return
            base
            .appending(path: "Aide", directoryHint: .isDirectory)
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "ggml-base.en.bin")
    }

    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["AIDE_RUN_STT_INTEGRATION"] == "1" else {
            throw XCTSkip("opt-in: set AIDE_RUN_STT_INTEGRATION=1 to run the real-decode check")
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("model not placed at \(modelURL.path) — see docs/native-deps.md")
        }
    }

    func testTranscribesSampleWAVWithPopulatedProbabilities() async throws {
        try requireOptIn()

        let wavURL = try XCTUnwrap(Bundle.module.url(forResource: "jfk", withExtension: "wav"))
        let samples = try WAVLoader.monoFloatSamples(at: wavURL)
        XCTAssertGreaterThan(samples.count, 0, "sample WAV decoded to no audio")

        let engine = WhisperSTTEngine(modelURL: modelURL)
        try await engine.ensureLoaded()
        let transcription = try await engine.transcribe(
            PCMBuffer(samples: samples, sampleRate: PCMBuffer.whisperSampleRate),
            language: .auto,
            initialPrompt: nil)

        // Real words from the JFK inaugural clip.
        let lowered = transcription.text.lowercased()
        XCTAssertTrue(lowered.contains("ask not"), "unexpected transcript: \(transcription.text)")
        XCTAssertTrue(lowered.contains("country"), "unexpected transcript: \(transcription.text)")

        // Per-segment probability metadata must be populated (the Pre-Gate's raw signal).
        XCTAssertFalse(transcription.segments.isEmpty)
        let segment = try XCTUnwrap(transcription.segments.first)
        XCTAssertGreaterThan(segment.tokenCount, 0)
        XCTAssertTrue(segment.avgLogprob.isFinite)
        XCTAssertLessThan(segment.avgLogprob, 0, "speech logprob should be negative")
        XCTAssertTrue((0...1).contains(segment.noSpeechProb), "noSpeechProb out of range")
        XCTAssertGreaterThan(segment.compressionRatio, 0)

        // The token-weighted utterance confidence is a real, finite, negative logprob.
        XCTAssertTrue(transcription.utteranceAvgLogprob.isFinite)
        XCTAssertLessThan(transcription.utteranceAvgLogprob, 0)
    }

    /// Phase 2 wiring: the Segment-Probability Pre-Gate runs **after** the real decode in
    /// the still-file-fed path, so its verdict is observable end-to-end. A clean clip must
    /// `pass` even under the strict (command) mode — the forwarded text still carries the
    /// recognized words, and the confidence is a finite, negative logprob (specs/P2a
    /// Phase 2; docs/05-lld.md §4.1).
    func testSampleWAVPassesPreGate() async throws {
        try requireOptIn()

        let wavURL = try XCTUnwrap(Bundle.module.url(forResource: "jfk", withExtension: "wav"))
        let samples = try WAVLoader.monoFloatSamples(at: wavURL)

        let engine = WhisperSTTEngine(modelURL: modelURL)
        try await engine.ensureLoaded()
        let transcription = try await engine.transcribe(
            PCMBuffer(samples: samples, sampleRate: PCMBuffer.whisperSampleRate),
            language: .auto,
            initialPrompt: nil)

        let verdict = SegmentPreGate(thresholds: .provisional).evaluate(transcription, mode: .command)
        guard case .pass(let text, let confidence) = verdict else {
            return XCTFail("the good jfk clip must pass the Pre-Gate; got \(verdict)")
        }
        XCTAssertTrue(text.lowercased().contains("country"), "forwarded text lost the recognized words: \(text)")
        XCTAssertTrue(confidence.isFinite)
        XCTAssertLessThan(confidence, 0)
    }
}

/// Headless guards on `WhisperSTTEngine.transcribe` that reject/short-circuit malformed
/// input **before** `ensureLoaded()` ever touches the model (code-review findings #1/#2
/// on the sample-rate and empty-PCM guards). Unlike `WhisperSTTEngineIntegrationTests`
/// above, these need no `AIDE_RUN_STT_INTEGRATION` opt-in and no placed model file, so
/// they run in the normal `just test` / `swift test` gate.
final class WhisperSTTEngineGuardTests: XCTestCase {

    /// Any URL works here: both guards below fire before `ensureLoaded()` would ever
    /// look at it, so no file needs to exist at this path.
    private var untouchedModelURL: URL {
        URL(fileURLWithPath: "/nonexistent/ggml-model-never-loaded.bin")
    }

    func testTranscribeThrowsUnsupportedSampleRateBeforeTouchingModel() async throws {
        let engine = WhisperSTTEngine(modelURL: untouchedModelURL)
        let pcm = PCMBuffer(samples: [0.1, -0.2, 0.3], sampleRate: 48_000)

        do {
            _ = try await engine.transcribe(pcm, language: .auto, initialPrompt: nil)
            XCTFail("expected .unsupportedSampleRate to be thrown")
        } catch let error as WhisperSTTEngineError {
            XCTAssertEqual(error, .unsupportedSampleRate(48_000))
        }
    }

    func testTranscribeOfEmptyPCMReturnsEmptyTranscriptionWithoutTouchingModel() async throws {
        let engine = WhisperSTTEngine(modelURL: untouchedModelURL)
        let pcm = PCMBuffer(samples: [], sampleRate: PCMBuffer.whisperSampleRate)

        let transcription = try await engine.transcribe(pcm, language: .auto, initialPrompt: nil)

        XCTAssertEqual(transcription, Transcription(text: "", language: "auto", segments: []))
    }
}

/// A tiny PCM-16 mono WAV reader — enough for the committed 16 kHz fixture. The real
/// mic → PCM path (AVAudioEngine) is Phase 3; this exists only to feed the fixture into
/// the integration check without pulling AVFoundation into the test.
enum WAVLoader {
    enum Failure: Error { case notAWAV, unsupportedFormat, noDataChunk }

    static func monoFloatSamples(at url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 12,
            data.readASCII(at: 0, count: 4) == "RIFF",
            data.readASCII(at: 8, count: 4) == "WAVE"
        else { throw Failure.notAWAV }

        var bitsPerSample = 16
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = data.readASCII(at: offset, count: 4)
            let chunkSize = Int(data.readUInt32LE(at: offset + 4))
            let body = offset + 8

            if chunkID == "fmt " {
                bitsPerSample = Int(data.readUInt16LE(at: body + 14))
            } else if chunkID == "data" {
                guard bitsPerSample == 16 else { throw Failure.unsupportedFormat }
                let end = min(body + chunkSize, data.count)
                var samples: [Float] = []
                samples.reserveCapacity((end - body) / 2)
                var sampleOffset = body
                while sampleOffset + 2 <= end {
                    let raw = Int16(bitPattern: data.readUInt16LE(at: sampleOffset))
                    samples.append(Float(raw) / 32_768.0)
                    sampleOffset += 2
                }
                return samples
            }
            // Chunks are word-aligned: an odd size carries a pad byte.
            offset = body + chunkSize + (chunkSize & 1)
        }
        throw Failure.noDataChunk
    }
}

extension Data {
    fileprivate func readASCII(at index: Int, count: Int) -> String {
        String(bytes: self[index..<index + count], encoding: .ascii) ?? ""
    }
    fileprivate func readUInt16LE(at index: Int) -> UInt16 {
        UInt16(self[index]) | (UInt16(self[index + 1]) << 8)
    }
    fileprivate func readUInt32LE(at index: Int) -> UInt32 {
        UInt32(self[index]) | (UInt32(self[index + 1]) << 8) | (UInt32(self[index + 2]) << 16)
            | (UInt32(self[index + 3]) << 24)
    }
}
