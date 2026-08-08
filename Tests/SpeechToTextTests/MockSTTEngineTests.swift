import XCTest

@testable import SpeechToText

/// `MockSTTEngine` is the deterministic, native-binary-free conformer of `STTEngine`
/// that P4/P5 and the Pre-Gate suite develop against (specs/P2a §"Mock conformer";
/// User Story 23). It returns a caller-injected `Transcription` verbatim so tests own
/// the segment metadata they exercise.
final class MockSTTEngineTests: XCTestCase {

    private let canned = Transcription(
        text: "ask not what your country can do for you",
        language: "en",
        segments: [
            Segment(
                text: "ask not what your country can do for you",
                tStart: 0,
                tEnd: 4,
                avgLogprob: -0.31,
                noSpeechProb: 0.02,
                compressionRatio: 1.4,
                tokenCount: 11)
        ])

    func testReturnsInjectedTranscriptionDeterministically() async throws {
        let engine = MockSTTEngine(returning: canned)
        let pcm = PCMBuffer(samples: [0, 0, 0], sampleRate: PCMBuffer.whisperSampleRate)

        let first = try await engine.transcribe(pcm, language: .auto, initialPrompt: nil)
        let second = try await engine.transcribe(pcm, language: .auto, initialPrompt: nil)

        XCTAssertEqual(first, canned)
        XCTAssertEqual(first, second)
    }

    /// The mock ignores its audio input — the same canned result regardless of PCM.
    func testIgnoresAudioInput() async throws {
        let engine = MockSTTEngine(returning: canned)
        let withAudio = try await engine.transcribe(
            PCMBuffer(samples: [1, 2, 3], sampleRate: 16_000), language: .auto, initialPrompt: nil)
        let withoutAudio = try await engine.transcribe(
            PCMBuffer(samples: [], sampleRate: 16_000), language: .explicit("hi"), initialPrompt: "bias")
        XCTAssertEqual(withAudio, withoutAudio)
    }

    func testEnsureLoadedIsIdempotentAndCounts() async throws {
        let engine = MockSTTEngine(returning: canned)
        try await engine.ensureLoaded()
        try await engine.ensureLoaded()
        let count = await engine.ensureLoadedCallCount
        XCTAssertEqual(count, 2)
    }

    /// The default `.auto` language is the reachable path (User Story 4 — Hindi /
    /// code-mixed, no forced English) via the protocol-extension convenience overload.
    func testConvenienceTranscribeUsesAutoLanguage() async throws {
        let engine = MockSTTEngine(returning: canned)
        let result = try await engine.transcribe(PCMBuffer(samples: [0], sampleRate: 16_000))
        XCTAssertEqual(result, canned)
    }
}

/// `LanguageHint` maps to whisper's language code; `.auto` is the default, code-nil path.
final class LanguageHintTests: XCTestCase {
    func testAutoIsTheDefault() {
        XCTAssertEqual(LanguageHint.default, .auto)
    }

    func testAutoHasNoForcedCode() {
        XCTAssertNil(LanguageHint.auto.whisperCode)
    }

    func testExplicitCarriesItsCode() {
        XCTAssertEqual(LanguageHint.explicit("hi").whisperCode, "hi")
    }
}
