import Foundation

/// The deterministic, native-binary-free conformer of `STTEngine` (specs/P2a
/// §"Mock conformer"; User Story 23). It returns a caller-injected `Transcription`
/// verbatim, so P4 (routing), P5 (dictation), and the Pre-Gate suite can develop and
/// test against transcription without the whisper.cpp binary present. The real
/// `WhisperSTTEngine` swaps in behind the same protocol with no change to callers.
public actor MockSTTEngine: STTEngine {

    private let stub: Transcription

    /// How many times `ensureLoaded()` has been called — lets tests assert the warm-load
    /// lifecycle without a real model.
    public private(set) var ensureLoadedCallCount = 0

    /// - Parameter transcription: the canned result every `transcribe` call returns.
    public init(returning transcription: Transcription) {
        self.stub = transcription
    }

    public func ensureLoaded() async throws {
        ensureLoadedCallCount += 1
    }

    public func transcribe(
        _ pcm: PCMBuffer,
        language: LanguageHint,
        initialPrompt: String?
    ) async throws -> Transcription {
        stub
    }
}
