import Foundation
import Persistence

/// Failures from `DictionaryStore.record` that are not I/O errors.
public enum DictionaryStoreError: Error, Equatable, Sendable {
    /// Empty, whitespace-only, or case-insensitively identical pair.
    case invalidTermPair
}

/// Actor façade for `dictionary.json`. Load is in-memory only until the first
/// mutation; every mutation re-applies promotion + MRU and writes atomically
/// via `AtomicFileWriter` (docs/05-lld.md §2.7).
public actor DictionaryStore {

    private let fileURL: URL
    private let writer: AtomicFileWriter
    private let clock: @Sendable () -> Date
    private let config: BudgetConfig
    private let makeID: @Sendable () -> String

    private var document: DictionaryDocument
    private var didLoad = false

    public init(
        fileURL: URL,
        writer: AtomicFileWriter = AtomicFileWriter(),
        clock: @escaping @Sendable () -> Date = { Date() },
        config: BudgetConfig = .default,
        makeID: @escaping @Sendable () -> String = { "e_\(UUID().uuidString)" }
    ) {
        self.fileURL = fileURL
        self.writer = writer
        self.clock = clock
        self.config = config
        self.makeID = makeID
        self.document = .empty(hardCap: config.hardCap)
    }

    /// Missing or unreadable file → empty document, and nothing is written.
    public func load() {
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else {
            document = .empty(hardCap: config.hardCap)
            return
        }
        guard let decoded = try? DictionaryCodec.decode(data) else {
            document = .empty(hardCap: config.hardCap)
            return
        }
        document = decoded
    }

    public func record(mishearing: String, correctTerm: String) throws {
        try record(mishearing: mishearing, correct: correctTerm, source: .explicit)
    }

    public func record(mishearing: String, correct: String, source: DictionaryEntry.Source) throws {
        guard let pair = TermPairExtractor.extractExplicit(mishearing: mishearing, correct: correct) else {
            throw DictionaryStoreError.invalidTermPair
        }
        let now = clock()
        try persist { document in
            if let index = document.entries.firstIndex(where: {
                $0.correctTerm.caseInsensitiveCompare(pair.correctTerm) == .orderedSame
            }) {
                document.entries[index] = document.entries[index].merging(
                    mishearing: pair.mishearing,
                    source: source,
                    lastUsedAt: now)
            } else {
                document.entries.append(
                    DictionaryEntry(
                        id: makeID(),
                        correctTerm: pair.correctTerm,
                        mishearings: [pair.mishearing],
                        occurrenceCount: 1,
                        promoted: false,
                        source: source,
                        createdAt: now,
                        lastUsedAt: now))
            }
        }
    }

    public func remove(id: String) throws {
        try persist { document in
            document.entries.removeAll { $0.id == id }
        }
    }

    public func upsert(_ entry: DictionaryEntry) throws {
        try persist { document in
            if let index = document.entries.firstIndex(where: { $0.id == entry.id }) {
                document.entries[index] = entry
            } else {
                document.entries.append(entry)
            }
        }
    }

    public func allEntries() -> [DictionaryEntry] {
        ensureLoaded()
        return document.entries
    }

    public func promotedEntries() -> [DictionaryEntry] {
        ensureLoaded()
        return document.entries.filter(\.promoted)
    }

    private func persist(mutate: (inout DictionaryDocument) -> Void) throws {
        ensureLoaded()
        mutate(&document)
        document.schemaVersion = DictionaryDocument.currentSchemaVersion
        document.hardCap = config.hardCap
        document.entries = document.entries.map { PromotionPolicy.withPromotion($0, promoteMin: config.promoteMin) }
        document.entries = MRUEviction.evict(document.entries, cap: config.hardCap)
        try writer.write(try DictionaryCodec.encode(document), to: fileURL)
    }

    private func ensureLoaded() {
        if !didLoad {
            load()
        }
    }
}

extension DictionaryStore: DictionaryRecording {}
