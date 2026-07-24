import Foundation

/// An append-only JSONL log — one JSON object per line, greppable and tail-able
/// (User Stories 33/35; docs/05-lld.md §2.6). Aide's command history and script
/// execution logs are all this shape; the type is generic over `Codable` so a
/// later phase's concrete entry (e.g. P4's command-history record) plugs in with
/// no change here.
///
/// `Date`s serialize as ISO-8601 (UTC, millisecond) to match the LLD wire format,
/// so downstream phases inherit it for free. JSON keys are left to the entry (via
/// its `CodingKeys`) rather than a global `snake_case` strategy, which would mangle
/// acronym fields (`skillID` → `skill_id` on encode but `skillId` on decode). Local
/// only — zero telemetry (docs/03-architecture.md §10.1).
public struct HistoryLog: Sendable {

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Append one entry as a single JSON line.
    public func append<Entry: Encodable>(_ entry: Entry) throws {
        var line = try Self.encoder.encode(entry)
        line.append(0x0A)  // one object per line
        try appendData(line)
    }

    /// Read every entry back, in append order. A missing file reads as empty; a
    /// malformed line surfaces its decode error rather than being silently dropped.
    public func readAll<Entry: Decodable>(_ type: Entry.Type) throws -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return
            try data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { try Self.decoder.decode(Entry.self, from: Data($0)) }
    }

    // MARK: - Append

    private func appendData(_ data: Data) throws {
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL)
        }
    }

    // MARK: - Codec (shared, LLD §2.6 conventions)

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Timestamp.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = Timestamp.date(from: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO-8601 timestamp: \(raw)"))
            }
            return date
        }
        return decoder
    }()
}
