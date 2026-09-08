import Foundation

/// One dictation turn in `history/commands-YYYY-MM-DD.jsonl` (P5a Phase 5).
/// Lives in Dictation so Persistence is not a Dictation target dependency;
/// the App layer appends via `HistoryLog`.
public struct DictationHistoryEntry: Codable, Equatable, Sendable {
    public var ts: Date
    public var mode: String
    public var transcript: String
    public var cleaned: String?
    public var cleanupRan: Bool
    public var insertion: String
    public var destinationBundleID: String?

    public init(
        ts: Date = Date(),
        mode: String = "dictation",
        transcript: String,
        cleaned: String? = nil,
        cleanupRan: Bool,
        insertion: String,
        destinationBundleID: String?
    ) {
        self.ts = ts
        self.mode = mode
        self.transcript = transcript
        self.cleaned = cleaned
        self.cleanupRan = cleanupRan
        self.insertion = insertion
        self.destinationBundleID = destinationBundleID
    }

    enum CodingKeys: String, CodingKey {
        case ts
        case mode
        case transcript
        case cleaned
        case cleanupRan = "cleanup_ran"
        case insertion
        case destinationBundleID = "destination_bundle_id"
    }
}
