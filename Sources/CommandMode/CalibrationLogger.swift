import Foundation
import Persistence

/// Appends one ``CalibrationRecord`` JSONL line per Command Mode interaction
/// (docs/05-lld.md §4.2). The file URL is injected so tests write to a temp path
/// and production points at `StorageLayout.calibrationLogFile`.
///
/// I/O goes through ``FileAppender`` — this type does not reimplement append.
public struct CalibrationLogger: Sendable {

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Encode `record` as one JSON object followed by a newline, then append.
    public func append(_ record: CalibrationRecord) throws {
        var line = try Self.encoder.encode(record)
        line.append(0x0A)
        try FileAppender.append(line, to: fileURL)
    }

    // MARK: - Codec (ISO-8601 UTC milliseconds, matching Persistence JSONL)

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Timestamp.string(from: date))
        }
        return encoder
    }()
}
