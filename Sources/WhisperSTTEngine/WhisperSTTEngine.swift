import Compression
import Foundation
import SpeechToText
import whisper

/// Why a `WhisperSTTEngine` decode failed (docs/05-lld.md §3.2). Surfaced up to the
/// UI as a human-readable "speech model not ready" / "couldn't transcribe" state in a
/// later phase; here it keeps the C-bridge failures typed rather than fatal.
public enum WhisperSTTEngineError: Error, Equatable {
    /// No model file exists at the configured path (manual placement in P2a Phase 1;
    /// provisioning arrives in Phase 5).
    case modelNotFound(URL)
    /// whisper.cpp could not initialize a context from the model file.
    case modelLoadFailed(URL)
    /// `whisper_full` returned a non-zero status.
    case decodeFailed(Int32)
    /// `pcm.sampleRate` was not `PCMBuffer.whisperSampleRate` (16 kHz). `whisper_full`
    /// hard-assumes 16 kHz and silently decodes a mismatched buffer as garbage at
    /// *normal* confidence — a false-negative the Pre-Gate would pass — so this is
    /// checked explicitly rather than left to whisper.cpp.
    case unsupportedSampleRate(Int)
}

/// The effectful C-bridge conformer of `STTEngine` (specs/P2a §"Effectful shells"):
/// links the pinned whisper.cpp xcframework and runs the real **in-process,
/// batch-on-release** decode. It is an app-linked target — deliberately kept out of the
/// pure `SpeechToText` module and out of the fast `swift test` unit gate (the P1
/// `CGEventTap` precedent); its only automated coverage is the opt-in, env-gated
/// headless integration check.
///
/// An `actor` because whisper's context is not thread-safe and is kept **warm** across
/// utterances (loaded lazily on first use, reused thereafter — HLD §4.3, STT half).
public actor WhisperSTTEngine: STTEngine {

    /// Absolute path to the ggml Whisper model. In Phase 1 this is placed manually under
    /// the app's models dir; Phase 5's provisioning fills it automatically.
    private let modelURL: URL

    /// The warm `whisper_context *`; `nil` until `ensureLoaded()` runs.
    private var context: OpaquePointer?

    public init(modelURL: URL) {
        self.modelURL = modelURL
    }

    deinit {
        if let context {
            whisper_free(context)
        }
    }

    public func ensureLoaded() throws {
        guard context == nil else { return }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperSTTEngineError.modelNotFound(modelURL)
        }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true  // Metal acceleration from the prebuilt artifact.
        let loaded = modelURL.path.withCString { whisper_init_from_file_with_params($0, cparams) }
        guard let loaded else {
            throw WhisperSTTEngineError.modelLoadFailed(modelURL)
        }
        context = loaded
    }

    public func transcribe(
        _ pcm: PCMBuffer,
        language: LanguageHint,
        initialPrompt: String?
    ) throws -> Transcription {
        // Both guards below run before `ensureLoaded()`/model access — malformed input
        // is rejected before the model is even touched (testable model-free) and never
        // reaches the C decode. Order: the empty-check first, since an empty buffer is
        // the more degenerate case and short-circuits without caring about sample rate;
        // then the sample-rate guard, since `whisper_full` hard-assumes 16 kHz and would
        // otherwise silently decode a resampled-wrong buffer as garbage at *normal*
        // confidence — a false-negative the Pre-Gate would pass through.
        guard !pcm.samples.isEmpty else {
            return Transcription(text: "", language: language.whisperCode ?? "auto", segments: [])
        }
        guard pcm.sampleRate == PCMBuffer.whisperSampleRate else {
            throw WhisperSTTEngineError.unsupportedSampleRate(pcm.sampleRate)
        }

        try ensureLoaded()
        guard let context else {
            throw WhisperSTTEngineError.modelLoadFailed(modelURL)
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_timestamps = false
        params.single_segment = false
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))

        // Language resolution (User Story 4 — no forced English). `.auto` truly
        // auto-detects Hindi / code-mixed speech on a **multilingual** model (nil
        // language + detect flag, the whisper contract) — the production path. On an
        // English-only model (e.g. the `base.en` spike model) there is no other language
        // to detect, so `.auto` pins its sole language `"en"`: this is honest metadata,
        // not a hardcoded forcing of English over a capable model, and it avoids
        // whisper's spurious auto-detect on a single-language vocab. `.explicit` always
        // pins its code. Both C strings must outlive the `whisper_full` call, so the
        // decode runs inside their `withCString` scopes.
        let multilingual = whisper_is_multilingual(context) != 0
        let languageCode: String?
        let detectLanguage: Bool
        switch language {
        case .auto:
            languageCode = multilingual ? nil : "en"
            detectLanguage = multilingual
        case .explicit(let code):
            languageCode = code
            detectLanguage = false
        }

        // NOTE (P2b): `whisper_full` is a synchronous, potentially multi-second C call
        // that runs on the actor's cooperative-pool thread — deliberately deferred for
        // now (P2a is the only cooperative-pool tenant). Once P2b's LLM work shares that
        // pool, this blocking decode can starve it; revisit then by offloading the call
        // to a dedicated serial queue while keeping this actor as the serialization
        // point. No threading machinery added here yet.
        let status: Int32 = pcm.samples.withUnsafeBufferPointer { samples in
            Self.withOptionalCString(languageCode) { languagePointer in
                Self.withOptionalCString(initialPrompt) { promptPointer in
                    params.language = languagePointer
                    params.detect_language = detectLanguage
                    params.initial_prompt = promptPointer
                    return whisper_full(context, params, samples.baseAddress, Int32(samples.count))
                }
            }
        }
        guard status == 0 else {
            throw WhisperSTTEngineError.decodeFailed(status)
        }

        return Self.buildTranscription(from: context, requested: language)
    }

    // MARK: - Result mapping

    private static func buildTranscription(
        from context: OpaquePointer,
        requested language: LanguageHint
    ) -> Transcription {
        let eot = whisper_token_eot(context)
        let segmentCount = whisper_full_n_segments(context)
        var segments: [Segment] = []
        segments.reserveCapacity(Int(segmentCount))
        var fullText = ""

        for index in 0..<segmentCount {
            let text = whisper_full_get_segment_text(context, index).map { String(cString: $0) } ?? ""
            fullText += text

            // whisper's t0/t1 are in centiseconds (10 ms units).
            let tStart = Double(whisper_full_get_segment_t0(context, index)) / 100.0
            let tEnd = Double(whisper_full_get_segment_t1(context, index)) / 100.0

            // Segment avg logprob = mean of the *text* tokens' log-probabilities
            // (`whisper_token_data.plog`), excluding special/timestamp tokens (id ≥ EOT)
            // so silence/timestamp markers don't skew the confidence signal.
            let tokenCount = whisper_full_n_tokens(context, index)
            var logprobSum: Float = 0
            var textTokens = 0
            for tokenIndex in 0..<tokenCount {
                let token = whisper_full_get_token_data(context, index, tokenIndex)
                guard token.id < eot else { continue }
                logprobSum += token.plog
                textTokens += 1
            }
            // The `0` (max-confidence) fallback is safe only because a `textTokens == 0`
            // segment is weightless in `Transcription.utteranceAvgLogprob` (weighted by
            // `tokenCount`) and text-less, so the Pre-Gate's empty-check rejects it
            // before this value is ever thresholded.
            let avgLogprob = textTokens > 0 ? logprobSum / Float(textTokens) : 0

            segments.append(
                Segment(
                    text: text,
                    tStart: tStart,
                    tEnd: tEnd,
                    avgLogprob: avgLogprob,
                    noSpeechProb: whisper_full_get_segment_no_speech_prob(context, index),
                    compressionRatio: compressionRatio(of: text),
                    tokenCount: textTokens))
        }

        let languageId = whisper_full_lang_id(context)
        let detected =
            languageId >= 0
            ? (whisper_lang_str(languageId).map { String(cString: $0) } ?? "")
            : (language.whisperCode ?? "auto")

        return Transcription(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            language: detected,
            segments: segments)
    }

    /// Whisper's repetition/hallucination signal: UTF-8 byte length / compressed byte
    /// length (a looping transcript compresses well ⇒ a high ratio). This is a
    /// zlib-style (raw-DEFLATE) compression ratio: `COMPRESSION_ZLIB` in Apple's
    /// Compression framework emits raw DEFLATE (RFC 1951), omitting the ~6-byte zlib
    /// wrapper (2-byte header + 4-byte Adler-32) that OpenAI Whisper's `zlib.compress`
    /// includes — so Aide's ratio runs slightly higher than OpenAI's for the same text.
    /// The Pre-Gate (Phase 2)'s provisional threshold is retuned by calibration against
    /// this exact signal, not against OpenAI's.
    private static func compressionRatio(of text: String) -> Float {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return 0 }
        let capacity = bytes.count + 64
        var destination = [UInt8](repeating: 0, count: capacity)
        let compressedCount = destination.withUnsafeMutableBufferPointer { destinationBuffer in
            bytes.withUnsafeBufferPointer { sourceBuffer in
                compression_encode_buffer(
                    destinationBuffer.baseAddress!, capacity,
                    sourceBuffer.baseAddress!, bytes.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard compressedCount > 0 else { return 0 }
        return Float(bytes.count) / Float(compressedCount)
    }

    /// Call `body` with a C-string pointer for `string`, or `nil` when it is `nil`. The
    /// pointer is valid only for the duration of `body` — whisper's `language` /
    /// `initial_prompt` are read synchronously inside `whisper_full`.
    private static func withOptionalCString<Result>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let string else { return body(nil) }
        return string.withCString(body)
    }
}
