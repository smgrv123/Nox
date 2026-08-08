import AideCore
import Foundation

/// The provisional thresholds the Segment-Probability Pre-Gate reads (docs/05-lld.md
/// §4.1). Every value is **PROVISIONAL** — the day-one calibration harness (§7) replaces
/// them with data-fitted numbers after ~1 week — so they are **injected**, never
/// hardcoded final inside the gate. Callers construct the gate with `.provisional`;
/// tests inject their own.
public struct PreGateThresholds: Equatable, Sendable {
    /// Step 1 non-speech drop — a segment is discarded only when its `noSpeechProb` is
    /// **strictly greater** than this AND its `avgLogprob` is below `nonSpeechMaxAvgLogprob`.
    public let nonSpeechMinNoSpeechProb: Float
    /// Step 1 non-speech drop — the `avgLogprob` a segment must be **strictly below**
    /// (together with the no-speech condition) to be dropped as silence/noise.
    public let nonSpeechMaxAvgLogprob: Float
    /// Step 3 repetition ceiling — a retained segment whose `compressionRatio` is
    /// **strictly greater** than this is a Whisper loop/hallucination artifact.
    public let repetitionMaxCompressionRatio: Float
    /// Step 5 confidence floor — a token-weighted utterance confidence **strictly below**
    /// this fails in command mode (skipped in dictation mode).
    public let minUtteranceAvgLogprob: Float

    public init(
        nonSpeechMinNoSpeechProb: Float,
        nonSpeechMaxAvgLogprob: Float,
        repetitionMaxCompressionRatio: Float,
        minUtteranceAvgLogprob: Float
    ) {
        self.nonSpeechMinNoSpeechProb = nonSpeechMinNoSpeechProb
        self.nonSpeechMaxAvgLogprob = nonSpeechMaxAvgLogprob
        self.repetitionMaxCompressionRatio = repetitionMaxCompressionRatio
        self.minUtteranceAvgLogprob = minUtteranceAvgLogprob
    }

    /// The **PROVISIONAL** defaults from docs/05-lld.md §4.1. NOT final: the calibration
    /// harness retunes these. The literals live *here only* (never inline in the gate or
    /// in a test assertion) so retuning is a one-line change with no ripple.
    public static let provisional = PreGateThresholds(
        nonSpeechMinNoSpeechProb: 0.60,
        nonSpeechMaxAvgLogprob: -1.0,
        repetitionMaxCompressionRatio: 2.4,
        minUtteranceAvgLogprob: -1.0)
}

/// Why the Pre-Gate rejected an utterance (docs/05-lld.md §4.1). Each maps to the same
/// honest "I didn't catch that — try again" re-ask (§9.x error table), but the reason is
/// preserved for the calibration record and for future differentiated UX.
public enum PreGateFailReason: Equatable, Sendable {
    /// Silence/noise: nothing survived the non-speech drop, or the survivors carry no
    /// words (whitespace/punctuation only).
    case noSpeech
    /// A Whisper repetition/hallucination loop (high compression ratio).
    case repetitionArtifact
    /// Real speech, but the model's own confidence is below the floor — command mode only.
    case lowConfidenceSTT
}

/// The Pre-Gate's decision (docs/05-lld.md §4.1). `pass` carries exactly what the Router
/// needs downstream — the forwarded text (over retained segments) and the recomputed
/// token-weighted utterance confidence (also logged into the calibration record, §4.2).
public enum PreGateVerdict: Equatable, Sendable {
    case pass(text: String, utteranceAvgLogprob: Float)
    case fail(reason: PreGateFailReason)
}

/// The **Whisper Segment-Probability Pre-Gate** — the marquee deep module and
/// safety-shaped core of P2a (docs/05-lld.md §4.1). It is the first safety gate: reject
/// low-quality transcriptions *before* they reach the Router, so garbage audio can never
/// route to a skill.
///
/// **Posture (shared with the Dangerous-Command Scanner):** loose-and-safe. On any
/// borderline the gate prefers a re-ask over a silent bad route. A re-ask (false
/// positive) is acceptable; a false "this audio is good" that lets garbage through (false
/// negative) is a defect.
///
/// **Purity:** no I/O, no native binary, deterministic. Its only inputs are a
/// `Transcription` (whisper's per-segment probabilities), the session `mode`, and the
/// injected `thresholds` — so it is exhaustively unit-tested headlessly.
///
/// **Mode asymmetry:** command mode is **strict** (all steps); dictation mode is
/// **lenient** — steps 1–3 still apply, but the confidence threshold (step 5) is skipped,
/// because dictation output flows through a human-visible cleanup+insert, not an
/// executable channel.
public struct SegmentPreGate: Sendable {

    /// The injected provisional thresholds (never hardcoded final inside the gate).
    public let thresholds: PreGateThresholds

    public init(thresholds: PreGateThresholds) {
        self.thresholds = thresholds
    }

    /// Apply the §4.1 pipeline to `transcription` under `mode`.
    public func evaluate(_ transcription: Transcription, mode: VoiceSessionMode) -> PreGateVerdict {
        // Step 1 — Drop non-speech segments (silence/noise); keeping them poisons the mean.
        let retained = transcription.segments.filter { !isNonSpeech($0) }

        // Step 2 — Empty check: nothing survived, or the survivors carry no actual words.
        let forwardedText = retained.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !retained.isEmpty, hasSpeechContent(forwardedText) else {
            return .fail(reason: .noSpeech)
        }

        // Step 3 — Repetition/hallucination: any retained loop artifact rejects the whole.
        if retained.contains(where: { $0.compressionRatio > thresholds.repetitionMaxCompressionRatio }) {
            return .fail(reason: .repetitionArtifact)
        }

        // Step 4 — Utterance confidence, recomputed over the RETAINED segments only. We
        // reuse `Transcription.utteranceAvgLogprob`'s tested token-weighted arithmetic by
        // evaluating it over just the survivors — NOT over the original (all-segment)
        // transcription, whose mean the dropped non-speech would corrupt.
        let utteranceAvgLogprob = Transcription(
            text: forwardedText,
            language: transcription.language,
            segments: retained
        ).utteranceAvgLogprob

        // Step 5 — Confidence threshold. Command mode only; dictation is lenient and skips
        // it (its output is human-visible, not an executable channel).
        if mode == .command {
            // A zero total token count over the retained segments makes
            // `utteranceAvgLogprob` fall back to `Transcription`'s divide-by-zero guard,
            // which returns a neutral `0` — the value nearest MAXIMUM confidence, not
            // minimum. Left unchecked, that optimistic `0` would clear
            // `0 < minUtteranceAvgLogprob` and let a zero-confidence utterance pass. Fail
            // it explicitly, before the threshold comparison can be fooled by it.
            let retainedTokenCount = retained.reduce(0) { $0 + $1.tokenCount }
            if retainedTokenCount == 0 || utteranceAvgLogprob < thresholds.minUtteranceAvgLogprob {
                return .fail(reason: .lowConfidenceSTT)
            }
        }

        // Step 6 — Pass: forward the text + confidence to the Router.
        return .pass(text: forwardedText, utteranceAvgLogprob: utteranceAvgLogprob)
    }

    /// Step 1's drop test. **AND, not OR** (docs/05-lld.md §4.1): a segment is non-speech
    /// only when it looks like silence/noise (`noSpeechProb` above the threshold) *and*
    /// the model was unsure of it (`avgLogprob` below the floor). A confident segment that
    /// merely tripped the no-speech prob is kept — dropping it would lose real speech.
    private func isNonSpeech(_ segment: Segment) -> Bool {
        segment.noSpeechProb > thresholds.nonSpeechMinNoSpeechProb
            && segment.avgLogprob < thresholds.nonSpeechMaxAvgLogprob
    }

    /// True iff `text` contains at least one alphanumeric scalar — i.e. an actual word or
    /// number. Whitespace-, punctuation-, and symbol-only survivors carry no speech, so
    /// they fail the empty check (the safe, re-ask direction). Unicode-aware, so Hindi /
    /// code-mixed scripts count as content (User Story 4).
    private func hasSpeechContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
