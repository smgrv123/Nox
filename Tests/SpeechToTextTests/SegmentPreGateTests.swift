import AideCore
import XCTest

@testable import SpeechToText

/// `SegmentPreGate` is the safety-shaped core of P2a (docs/05-lld.md §4.1): it reads
/// whisper's per-segment probabilities and decides *pass* vs *re-ask* **before** any
/// text can reach the Router. Its failure mode to design against is a false "this audio
/// is good" that lets garbage through — a re-ask (false positive) is acceptable, a
/// garbage-passes-as-good (false negative) is a defect. So this suite pins every §4.1
/// step, the command/dictation asymmetry, the strictly-`>` boundaries, and the
/// recompute-over-*retained*-segments rule.
///
/// **Thresholds are the injected provisional struct.** No threshold literal appears in
/// any assertion: each segment input is built *relative* to the injected thresholds
/// ("above / below the floor"), and assertions check only the verdict shape (or an
/// arithmetic mean) — so the future calibration harness can retune the numbers without
/// touching this file.
final class SegmentPreGateTests: XCTestCase {

    /// Test-local thresholds. Deliberately NOT `.provisional`: the suite owns its own
    /// injected values so it never depends on the production defaults, and every segment
    /// below is constructed relative to *these*.
    private let thresholds = PreGateThresholds(
        nonSpeechMinNoSpeechProb: 0.60,
        nonSpeechMaxAvgLogprob: -1.0,
        repetitionMaxCompressionRatio: 2.4,
        minUtteranceAvgLogprob: -1.0)

    private var gate: SegmentPreGate { SegmentPreGate(thresholds: thresholds) }

    // MARK: - Builders (inputs, relative to the injected thresholds)

    /// A clear speech segment: low no-speech prob, logprob well above the floor, normal
    /// compression, real alphanumeric text. Callers override only the field under test.
    private func speech(
        _ text: String = "hello",
        avgLogprob: Float = -0.2,
        noSpeechProb: Float = 0.05,
        compressionRatio: Float = 1.5,
        tokenCount: Int = 4
    ) -> Segment {
        Segment(
            text: text,
            tStart: 0,
            tEnd: 1,
            avgLogprob: avgLogprob,
            noSpeechProb: noSpeechProb,
            compressionRatio: compressionRatio,
            tokenCount: tokenCount)
    }

    /// A non-speech segment that satisfies BOTH drop conditions (§4.1 step 1): no-speech
    /// prob clearly above the threshold AND avg logprob clearly below it.
    private func nonSpeech(_ text: String = "[BLANK_AUDIO]") -> Segment {
        speech(
            text,
            avgLogprob: thresholds.nonSpeechMaxAvgLogprob - 0.5,
            noSpeechProb: thresholds.nonSpeechMinNoSpeechProb + 0.2,
            compressionRatio: 1.0,
            tokenCount: 3)
    }

    private func transcription(_ segments: [Segment]) -> Transcription {
        Transcription(text: "unused", language: "en", segments: segments)
    }

    // MARK: - Step 1: drop non-speech segments

    /// A non-speech segment is discarded — its text is not forwarded.
    func testNonSpeechSegmentDroppedFromForwardedText() {
        let verdict = gate.evaluate(
            transcription([speech("ask not"), nonSpeech("[BLANK_AUDIO]")]),
            mode: .command)
        guard case .pass(let text, _) = verdict else {
            return XCTFail("expected pass, got \(verdict)")
        }
        XCTAssertTrue(text.contains("ask not"))
        XCTAssertFalse(text.contains("BLANK_AUDIO"), "dropped non-speech text must not be forwarded")
    }

    /// The drop is an **AND**, not an OR: a confident segment flagged only by a high
    /// no-speech prob is still speech and MUST be retained. (An OR would silently drop
    /// legitimate quiet-but-confident audio.)
    func testHighNoSpeechProbButConfidentSegmentIsRetained() {
        let flaggedButConfident = speech(
            "hello",
            avgLogprob: thresholds.nonSpeechMaxAvgLogprob + 0.5,  // above the floor ⇒ confident
            noSpeechProb: thresholds.nonSpeechMinNoSpeechProb + 0.2)  // above the prob threshold
        guard case .pass(let text, _) = gate.evaluate(transcription([flaggedButConfident]), mode: .command) else {
            return XCTFail("a confident segment flagged only by no-speech prob must be retained")
        }
        XCTAssertTrue(text.contains("hello"))
    }

    /// `noSpeechProb` exactly AT the threshold does not satisfy the drop's strict `>` —
    /// pins the boundary so a future flip to `>=` would go uncaught. `avgLogprob` is set
    /// clearly below `nonSpeechMaxAvgLogprob` so the *other* half of the step-1 AND is
    /// unambiguously true; only the strict `>` on `noSpeechProb` decides retention here.
    /// Uses dictation mode to isolate step 1 from step 5's confidence floor (this test
    /// thresholds set `nonSpeechMaxAvgLogprob` and `minUtteranceAvgLogprob` to the same
    /// value, so a deliberately-low `avgLogprob` would otherwise also trip step 5).
    func testNoSpeechProbExactlyAtThresholdIsRetained() {
        let atThreshold = speech(
            "hello world",
            avgLogprob: thresholds.nonSpeechMaxAvgLogprob - 0.5,  // clearly below the floor
            noSpeechProb: thresholds.nonSpeechMinNoSpeechProb,  // exactly at, not above
            tokenCount: 6)
        guard case .pass(let text, _) = gate.evaluate(transcription([atThreshold]), mode: .dictation) else {
            return XCTFail("noSpeechProb exactly at the threshold must not be dropped (drop requires strictly >)")
        }
        XCTAssertTrue(text.contains("hello"), "a retained segment's text must be forwarded")
    }

    /// `avgLogprob` exactly AT the floor does not satisfy the drop's strict `<` — pins the
    /// other half of the step-1 boundary. `noSpeechProb` is set clearly above
    /// `nonSpeechMinNoSpeechProb` so the first half of the AND is unambiguously true; only
    /// the strict `<` on `avgLogprob` decides retention here. Dictation mode again isolates
    /// step 1 from step 5 (see note above).
    func testAvgLogprobExactlyAtFloorIsRetained() {
        let atFloor = speech(
            "hello world",
            avgLogprob: thresholds.nonSpeechMaxAvgLogprob,  // exactly at, not below
            noSpeechProb: thresholds.nonSpeechMinNoSpeechProb + 0.2,  // clearly above
            tokenCount: 6)
        guard case .pass(let text, _) = gate.evaluate(transcription([atFloor]), mode: .dictation) else {
            return XCTFail("avgLogprob exactly at the floor must not be dropped (drop requires strictly <)")
        }
        XCTAssertTrue(text.contains("hello"), "a retained segment's text must be forwarded")
    }

    // MARK: - Step 2: empty / whitespace-only → .noSpeech

    func testNoSegmentsAtAllIsNoSpeech() {
        XCTAssertEqual(gate.evaluate(transcription([]), mode: .command), .fail(reason: .noSpeech))
    }

    func testAllSegmentsDroppedLeavesNoSpeech() {
        XCTAssertEqual(
            gate.evaluate(transcription([nonSpeech(), nonSpeech()]), mode: .command), .fail(reason: .noSpeech))
    }

    /// A segment that SURVIVES the non-speech drop (confident, low no-speech prob) but
    /// whose text is whitespace/punctuation only carries no words → still `.noSpeech`.
    func testWhitespaceAndPunctuationOnlyIsNoSpeech() {
        let punctuationOnly = speech("  ...  ", tokenCount: 2)
        XCTAssertEqual(gate.evaluate(transcription([punctuationOnly]), mode: .command), .fail(reason: .noSpeech))
    }

    // MARK: - Step 3: repetition / hallucination

    func testHighCompressionRatioIsRepetitionArtifact() {
        let looping = speech(
            "go go go go go",
            compressionRatio: thresholds.repetitionMaxCompressionRatio + 0.5,  // over the ceiling
            tokenCount: 10)
        XCTAssertEqual(gate.evaluate(transcription([looping]), mode: .command), .fail(reason: .repetitionArtifact))
    }

    /// A segment exactly AT the ceiling is not a repetition artifact — pins the strict
    /// `>` boundary from §4.1 (not `>=`).
    func testCompressionRatioExactlyAtCeilingIsNotRepetition() {
        let atCeiling = speech(
            "hello world",
            compressionRatio: thresholds.repetitionMaxCompressionRatio,
            tokenCount: 6)
        guard case .pass = gate.evaluate(transcription([atCeiling]), mode: .command) else {
            return XCTFail("compression ratio exactly at the ceiling must not fail")
        }
    }

    // MARK: - Step 4: utterance confidence recomputed over RETAINED segments only

    /// The confidence forwarded on `pass` is the token-weighted mean of the *retained*
    /// segments — a dropped non-speech segment (whose logprob is far below the floor)
    /// must not poison it. Guards against reusing `Transcription.utteranceAvgLogprob`,
    /// which is over ALL segments.
    func testUtteranceMeanRecomputedOverRetainedSegmentsOnly() {
        let first = speech("ask", avgLogprob: -0.2, compressionRatio: 1.2, tokenCount: 3)
        let second = speech("not", avgLogprob: -0.4, compressionRatio: 1.2, tokenCount: 1)
        let dropped = nonSpeech("[BLANK_AUDIO]")  // logprob far below the floor, discarded

        guard case .pass(_, let confidence) = gate.evaluate(transcription([first, second, dropped]), mode: .command)
        else {
            return XCTFail("expected pass")
        }

        // Retained-only token-weighted mean: (-0.2*3 + -0.4*1) / 4 = -0.25.
        let retainedOnlyMean: Float = (-0.2 * 3 + -0.4 * 1) / 4
        XCTAssertEqual(confidence, retainedOnlyMean, accuracy: 1e-6)

        // The all-segment mean (including the dropped noise) is materially different —
        // assert the gate did NOT compute over all segments.
        let allSegmentMean = transcription([first, second, dropped]).utteranceAvgLogprob
        XCTAssertNotEqual(confidence, allSegmentMean, accuracy: 1e-6)
    }

    // MARK: - Step 5: confidence floor (command mode only)

    func testLowConfidenceInCommandModeIsLowConfidenceSTT() {
        // Retained (low no-speech prob ⇒ not dropped) but the weighted mean is below the
        // command floor → re-ask.
        let quiet = speech(
            "maybe something",
            avgLogprob: thresholds.minUtteranceAvgLogprob - 0.3,  // below the floor
            tokenCount: 5)
        XCTAssertEqual(gate.evaluate(transcription([quiet]), mode: .command), .fail(reason: .lowConfidenceSTT))
    }

    /// A retained segment with real alphanumeric text but `tokenCount == 0` survives the
    /// text-based step-2 empty check, so step 4 recomputes `utteranceAvgLogprob` over a
    /// zero-total-token weighted mean — `Transcription`'s divide-by-zero guard returns the
    /// neutral `0`, which reads as MAXIMUM confidence and would otherwise clear
    /// `0 < minUtteranceAvgLogprob`. Command mode must not let that optimistic `0` bypass
    /// the confidence floor: zero tokens can never be trusted as "0 confidence" — they mean
    /// no confidence signal at all — so this must fail, not pass.
    func testZeroTokenCountWithTextInCommandModeIsLowConfidenceSTT() {
        let zeroTokenSegment = speech("hello there", tokenCount: 0)
        XCTAssertEqual(
            gate.evaluate(transcription([zeroTokenSegment]), mode: .command),
            .fail(reason: .lowConfidenceSTT))
    }

    /// Same zero-token input, but dictation mode: step 5 (where the zero-token guard
    /// lives) is skipped entirely in dictation, so the existing mode asymmetry means this
    /// still passes. Documents the deliberate choice to keep the asymmetry rather than
    /// special-casing zero tokens into dictation's leniency.
    func testZeroTokenCountWithTextInDictationModeStillPasses() {
        let zeroTokenSegment = speech("hello there", tokenCount: 0)
        guard case .pass = gate.evaluate(transcription([zeroTokenSegment]), mode: .dictation) else {
            return XCTFail("dictation skips the confidence step entirely, so zero tokens must still pass")
        }
    }

    // MARK: - Step 6: pass

    func testGoodUtterancePasses() {
        let verdict = gate.evaluate(
            transcription([speech("ask not what your country can do")]),
            mode: .command)
        guard case .pass(let text, let confidence) = verdict else {
            return XCTFail("a clean, confident utterance must pass; got \(verdict)")
        }
        XCTAssertTrue(text.contains("country"))
        XCTAssertTrue(confidence.isFinite)
    }

    // MARK: - Mode asymmetry (command strict vs dictation lenient)

    /// The marquee asymmetry: ONE borderline utterance clears steps 1–3 (real,
    /// non-looping speech) but its confidence sits just below the command floor. Command
    /// mode applies the threshold (step 5) → re-ask; dictation SKIPS it → pass. Same
    /// input, both modes.
    func testBorderlineFailsCommandButPassesDictation() {
        let borderline = transcription([
            speech(
                "did i say that right",
                avgLogprob: thresholds.minUtteranceAvgLogprob - 0.1,  // just below the floor
                compressionRatio: 1.6,
                tokenCount: 6)
        ])

        XCTAssertEqual(gate.evaluate(borderline, mode: .command), .fail(reason: .lowConfidenceSTT))

        guard case .pass = gate.evaluate(borderline, mode: .dictation) else {
            return XCTFail("dictation is lenient: the threshold step is skipped, so the same input must pass")
        }
    }

    /// Dictation leniency is NARROW — it skips only the confidence threshold. Steps 1–3
    /// still apply, so silence still re-asks (a false negative here would be a defect).
    func testDictationStillRejectsNoSpeech() {
        XCTAssertEqual(
            gate.evaluate(transcription([nonSpeech(), nonSpeech()]), mode: .dictation), .fail(reason: .noSpeech))
    }

    func testDictationStillRejectsRepetitionArtifact() {
        let looping = speech(
            "la la la la la",
            compressionRatio: thresholds.repetitionMaxCompressionRatio + 0.5,
            tokenCount: 10)
        XCTAssertEqual(
            gate.evaluate(transcription([looping]), mode: .dictation), .fail(reason: .repetitionArtifact))
    }
}
