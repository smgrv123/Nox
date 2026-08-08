import Foundation

/// One decoded segment of an utterance plus the raw Whisper probability metadata the
/// Segment-Probability Pre-Gate reads (docs/05-lld.md §3.2, §4.1). These fields are the
/// *only* signal the Pre-Gate has for deciding *pass* vs *re-ask*, so they are carried
/// verbatim from whisper.cpp — never rounded or re-derived on the way through.
///
/// - `avgLogprob`: mean of the segment's per-token log-probabilities (whisper's
///   `whisper_token_data.plog`); always ≤ 0, closer to 0 = more confident.
/// - `noSpeechProb`: whisper's no-speech probability for the segment; used to drop
///   silence/noise segments before they poison the utterance mean.
/// - `compressionRatio`: text-length / compressed-length; a repetition/hallucination
///   signal (Whisper loops compress well ⇒ a high ratio).
/// - `tokenCount`: number of decoded tokens; the weight in the utterance mean.
public struct Segment: Equatable, Sendable {
    public let text: String
    public let tStart: Double
    public let tEnd: Double
    public let avgLogprob: Float
    public let noSpeechProb: Float
    public let compressionRatio: Float
    public let tokenCount: Int

    public init(
        text: String,
        tStart: Double,
        tEnd: Double,
        avgLogprob: Float,
        noSpeechProb: Float,
        compressionRatio: Float,
        tokenCount: Int
    ) {
        self.text = text
        self.tStart = tStart
        self.tEnd = tEnd
        self.avgLogprob = avgLogprob
        self.noSpeechProb = noSpeechProb
        self.compressionRatio = compressionRatio
        self.tokenCount = tokenCount
    }
}

/// The result of transcribing one utterance: the joined text, the detected language
/// code, and the per-segment metadata (docs/05-lld.md §3.2). `utteranceAvgLogprob` is
/// the single confidence number the Pre-Gate thresholds on (§4.1).
public struct Transcription: Equatable, Sendable {
    /// The full recognized text (segments joined).
    public let text: String
    /// The detected (or forced) language code, e.g. `"en"`, `"hi"`.
    public let language: String
    /// Per-segment decode metadata, in utterance order.
    public let segments: [Segment]

    public init(text: String, language: String, segments: [Segment]) {
        self.text = text
        self.language = language
        self.segments = segments
    }

    /// The **token-count-weighted mean** of the segments' `avgLogprob` (docs/05-lld.md
    /// §3.2) — longer segments count proportionally more than a one-token fragment.
    ///
    /// Edge: with no segments, or a total token count of zero, the weighted mean is
    /// undefined; we return `0` rather than divide by zero (a `NaN` here would silently
    /// corrupt every Pre-Gate comparison downstream). `0` is a deliberately neutral,
    /// non-negative value — the empty-check step of the Pre-Gate rejects such a
    /// transcript on `.noSpeech` before this number is ever thresholded.
    public var utteranceAvgLogprob: Float {
        let totalTokens = segments.reduce(0) { $0 + $1.tokenCount }
        guard totalTokens > 0 else { return 0 }
        let weightedSum = segments.reduce(Float(0)) { $0 + $1.avgLogprob * Float($1.tokenCount) }
        return weightedSum / Float(totalTokens)
    }
}
