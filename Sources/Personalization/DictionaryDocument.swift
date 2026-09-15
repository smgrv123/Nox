import Foundation

/// The on-disk `dictionary.json` envelope (docs/05-lld.md §2.3). `schema_version`
/// is this document's version, not `Settings.currentSchemaVersion`.
public struct DictionaryDocument: Equatable, Sendable, Codable {

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var hardCap: Int
    public var entries: [DictionaryEntry]

    public init(schemaVersion: Int = currentSchemaVersion, hardCap: Int, entries: [DictionaryEntry]) {
        self.schemaVersion = schemaVersion
        self.hardCap = hardCap
        self.entries = entries
    }

    public static func empty(hardCap: Int) -> DictionaryDocument {
        DictionaryDocument(hardCap: hardCap, entries: [])
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case hardCap = "hard_cap"
        case entries
    }
}

/// Pure (de)serialisation of `dictionary.json` — no disk. Unknown `source` values
/// (and any other single-entry decode failure) drop that entry rather than
/// failing the document: reject-entry-on-load, never crash the app.
public enum DictionaryCodec {

    public static func encode(_ document: DictionaryDocument) throws -> Data {
        try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> DictionaryDocument {
        let raw = try decoder.decode(RawDocument.self, from: data)
        return DictionaryDocument(
            schemaVersion: raw.schemaVersion ?? DictionaryDocument.currentSchemaVersion,
            hardCap: raw.hardCap ?? BudgetConfig.default.hardCap,
            entries: raw.entries.compactMap(\.value))
    }

    private struct RawDocument: Decodable {
        var schemaVersion: Int?
        var hardCap: Int?
        var entries: [Failable<DictionaryEntry>]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DictionaryDocument.CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            hardCap = try container.decodeIfPresent(Int.self, forKey: .hardCap)
            entries = try container.decodeIfPresent([Failable<DictionaryEntry>].self, forKey: .entries) ?? []
        }
    }

    private struct Failable<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
