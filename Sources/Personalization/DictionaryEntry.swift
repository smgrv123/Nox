import Foundation

/// One canonical spelling plus the STT variants that should map to it
/// (docs/05-lld.md §2.3). `promoted` gates consumption by Whisper bias and
/// cleanup substitutions; `source` is `explicit` in v1 (the `auto` case is
/// architected but no caller creates it).
public struct DictionaryEntry: Equatable, Sendable, Codable {

    public enum Source: String, Equatable, Sendable, Codable {
        case explicit
        case auto
    }

    public var id: String
    public var correctTerm: String
    public var mishearings: [String]
    public var occurrenceCount: Int
    public var promoted: Bool
    public var source: Source
    public var createdAt: Date
    public var lastUsedAt: Date

    public init(
        id: String,
        correctTerm: String,
        mishearings: [String],
        occurrenceCount: Int,
        promoted: Bool,
        source: Source,
        createdAt: Date,
        lastUsedAt: Date
    ) {
        self.id = id
        self.correctTerm = correctTerm
        self.mishearings = mishearings
        self.occurrenceCount = occurrenceCount
        self.promoted = promoted
        self.source = source
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// LLD §4.5A found-entry merge: dedup mishearing (case-insensitive), bump
    /// `occurrenceCount`, refresh `lastUsedAt`, and upgrade `source` to `.explicit`
    /// when the incoming observation is explicit.
    public func merging(mishearing: String, source: Source, lastUsedAt now: Date) -> DictionaryEntry {
        var next = self
        next.mishearings = Self.adding(mishearing, to: mishearings)
        next.occurrenceCount += 1
        next.lastUsedAt = now
        if source == .explicit {
            next.source = .explicit
        }
        return next
    }

    private static func adding(_ mishearing: String, to existing: [String]) -> [String] {
        if existing.contains(where: { $0.caseInsensitiveCompare(mishearing) == .orderedSame }) {
            return existing
        }
        return existing + [mishearing]
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case correctTerm = "correct_term"
        case mishearings
        case occurrenceCount = "occurrence_count"
        case promoted
        case source
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.correctTerm = try container.decode(String.self, forKey: .correctTerm)
        self.mishearings = try container.decode([String].self, forKey: .mishearings)
        self.occurrenceCount = try container.decode(Int.self, forKey: .occurrenceCount)
        self.promoted = try container.decode(Bool.self, forKey: .promoted)
        self.source = try container.decode(Source.self, forKey: .source)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt) ?? Date.distantPast
    }
    // `encode(to:)` is synthesised from `CodingKeys` — still writes `last_used_at`.
}
