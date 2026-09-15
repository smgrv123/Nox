import Foundation

/// How a dictation turn's text ended up at (or near) the caret.
///
/// The raw values are what's persisted in `history/commands-YYYY-MM-DD.jsonl`
/// under the `insertion` key — see `DictationHistoryEntry`.
public enum InsertionKind: String, Codable, Equatable, Sendable {
    /// Retained for backward compatibility only: AX insertion was removed (dictation
    /// always pastes now — see `TextInserting`), so nothing produces `.ax` any more.
    /// Existing `history/commands-*.jsonl` lines still carry `"insertion":"ax"` and
    /// must keep decoding.
    case ax
    case paste
    case copied
    case failed
}

/// One dictation turn in `history/commands-YYYY-MM-DD.jsonl` (P5a Phase 5).
/// Lives in Dictation so Persistence is not a Dictation target dependency;
/// the App layer appends via `HistoryLog`.
public struct DictationHistoryEntry: Codable, Equatable, Sendable {
    public var ts: Date
    public var mode: String
    public var transcript: String
    public var cleaned: String?
    public var cleanupRan: Bool
    public var insertion: InsertionKind
    public var destinationBundleID: String?

    // MARK: - Latency instrumentation (P5a)
    //
    // All optional/defaulted — a missing stage (cleanup skipped, model already warm)
    // is distinguishable from a genuinely zero-duration one, and older lines written
    // before this change still decode. Milliseconds, `ContinuousClock`-measured
    // (monotonic; never wall-clock `Date`) at the call site, not here.

    /// Duration of the captured audio itself — PCM sample count ÷ sample rate.
    public var audioMs: Int?
    /// Time in `engine.transcribe(...)`.
    public var sttMs: Int?
    /// Time in `engine.ensureLoaded()` — near-zero when the model was already warm.
    public var modelLoadMs: Int?
    /// The whole cleanup step (endpoint resolve + chat + sanitize); nil when cleanup
    /// didn't run (mirrors `cleanupRan`).
    public var cleanupMs: Int?
    /// Time in `inserter.insert(...)`.
    public var insertMs: Int?
    /// End of audio capture → insertion complete — closest to what the user feels.
    public var totalMs: Int?

    public init(
        ts: Date = Date(),
        mode: String = "dictation",
        transcript: String,
        cleaned: String? = nil,
        cleanupRan: Bool,
        insertion: InsertionKind,
        destinationBundleID: String?,
        audioMs: Int? = nil,
        sttMs: Int? = nil,
        modelLoadMs: Int? = nil,
        cleanupMs: Int? = nil,
        insertMs: Int? = nil,
        totalMs: Int? = nil
    ) {
        self.ts = ts
        self.mode = mode
        self.transcript = transcript
        self.cleaned = cleaned
        self.cleanupRan = cleanupRan
        self.insertion = insertion
        self.destinationBundleID = destinationBundleID
        self.audioMs = audioMs
        self.sttMs = sttMs
        self.modelLoadMs = modelLoadMs
        self.cleanupMs = cleanupMs
        self.insertMs = insertMs
        self.totalMs = totalMs
    }

    enum CodingKeys: String, CodingKey {
        case ts
        case mode
        case transcript
        case cleaned
        case cleanupRan = "cleanup_ran"
        case insertion
        case destinationBundleID = "destination_bundle_id"
        case audioMs = "audio_ms"
        case sttMs = "stt_ms"
        case modelLoadMs = "model_load_ms"
        case cleanupMs = "cleanup_ms"
        case insertMs = "insert_ms"
        case totalMs = "total_ms"
    }
}
