import XCTest

@testable import SpeechToText

/// `Transcription.utteranceAvgLogprob` is the token-count-weighted mean of the
/// per-segment `avgLogprob` (docs/05-lld.md §3.2). It is the raw confidence signal the
/// Pre-Gate thresholds on (§4.1, Phase 2), so its arithmetic is pinned here test-first.
final class TranscriptionTests: XCTestCase {

    private func segment(avgLogprob: Float, tokenCount: Int) -> Segment {
        Segment(
            text: "x",
            tStart: 0,
            tEnd: 1,
            avgLogprob: avgLogprob,
            noSpeechProb: 0.1,
            compressionRatio: 1.5,
            tokenCount: tokenCount)
    }

    private func transcription(_ segments: [Segment]) -> Transcription {
        Transcription(text: "x", language: "en", segments: segments)
    }

    /// Equal token counts ⇒ the weighted mean is the plain mean.
    func testWeightedMeanWithEqualTokenCountsIsPlainMean() {
        let sut = transcription([
            segment(avgLogprob: -0.2, tokenCount: 5),
            segment(avgLogprob: -0.8, tokenCount: 5),
        ])
        XCTAssertEqual(sut.utteranceAvgLogprob, -0.5, accuracy: 1e-6)
    }

    /// A segment with more tokens pulls the mean toward its value — the "token-count
    /// weighted" property (not a plain average of the two segment values).
    func testWeightedMeanFavorsSegmentWithMoreTokens() {
        let sut = transcription([
            segment(avgLogprob: -0.1, tokenCount: 9),  // dominant
            segment(avgLogprob: -1.1, tokenCount: 1),
        ])
        // (-0.1*9 + -1.1*1) / 10 = -2.0/10 = -0.2
        XCTAssertEqual(sut.utteranceAvgLogprob, -0.2, accuracy: 1e-6)
        // A plain (unweighted) mean would be -0.6 — assert we are NOT that.
        XCTAssertNotEqual(sut.utteranceAvgLogprob, -0.6, accuracy: 1e-6)
    }

    /// Single segment ⇒ the utterance value is that segment's value.
    func testSingleSegment() {
        let sut = transcription([segment(avgLogprob: -0.37, tokenCount: 12)])
        XCTAssertEqual(sut.utteranceAvgLogprob, -0.37, accuracy: 1e-6)
    }

    /// Empty edge: no segments ⇒ 0, never a divide-by-zero / NaN.
    func testNoSegmentsIsZeroNotNaN() {
        let sut = transcription([])
        XCTAssertEqual(sut.utteranceAvgLogprob, 0)
        XCTAssertFalse(sut.utteranceAvgLogprob.isNaN)
    }

    /// Zero-token edge: segments exist but carry zero tokens (total weight 0) ⇒ 0,
    /// never a divide-by-zero / NaN. Guards the exact denominator the Pre-Gate relies on.
    func testZeroTotalTokensIsZeroNotNaN() {
        let sut = transcription([
            segment(avgLogprob: -0.4, tokenCount: 0),
            segment(avgLogprob: -0.9, tokenCount: 0),
        ])
        XCTAssertEqual(sut.utteranceAvgLogprob, 0)
        XCTAssertFalse(sut.utteranceAvgLogprob.isNaN)
        XCTAssertFalse(sut.utteranceAvgLogprob.isInfinite)
    }
}
