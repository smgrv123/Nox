import AideCore
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

    /// Process-local, in-memory only (never persisted to `dictionary.json` — this is
    /// cache-invalidation state, not schema). Bumped inside `persist(mutate:)` so every
    /// mutating method gets it for free; reads (`allEntries`, `promotedEntries`, `load`)
    /// never touch it. Lets callers such as the Whisper bias-prompt cache
    /// (`BiasPromptCache`, docs/05-lld.md §4.5D.4) recompute lazily and invalidate only
    /// on an actual dictionary change.
    private var generationCounter = 0

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
            upsertByCorrectTerm(
                pair.correctTerm,
                in: &document,
                ifFound: { entry in
                    entry = entry.merging(mishearing: pair.mishearing, source: source, lastUsedAt: now)
                },
                ifNotFound: {
                    DictionaryEntry(
                        id: makeID(),
                        correctTerm: pair.correctTerm,
                        mishearings: [pair.mishearing],
                        occurrenceCount: 1,
                        promoted: false,
                        source: source,
                        createdAt: now,
                        lastUsedAt: now)
                })
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

    public func replaceAll(_ entries: [DictionaryEntry]) throws {
        try persist { document in
            document.entries = entries
        }
    }

    /// Settings-pane add: `correctTerm` is required; `mishearing` may be empty so the
    /// user can stash custom vocabulary before any STT variant is known.
    public func addExplicit(correctTerm: String, mishearing: String) throws {
        let heard = mishearing.trimmingCharacters(in: .whitespacesAndNewlines)
        if heard.isEmpty {
            let term = correctTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { throw DictionaryStoreError.invalidTermPair }
            let now = clock()
            try persist { document in
                upsertByCorrectTerm(
                    term,
                    in: &document,
                    ifFound: { entry in
                        entry.occurrenceCount += 1
                        entry.lastUsedAt = now
                        entry.source = .explicit
                    },
                    ifNotFound: {
                        DictionaryEntry(
                            id: makeID(),
                            correctTerm: term,
                            mishearings: [],
                            occurrenceCount: 1,
                            promoted: false,
                            source: .explicit,
                            createdAt: now,
                            lastUsedAt: now)
                    })
            }
            return
        }
        try record(mishearing: heard, correct: correctTerm, source: .explicit)
    }

    public func allEntries() -> [DictionaryEntry] {
        ensureLoaded()
        return document.entries
    }

    public func promotedEntries() -> [DictionaryEntry] {
        ensureLoaded()
        return document.entries.filter(\.promoted)
    }

    /// Current generation: incremented once per successful `persist(mutate:)` call
    /// (i.e. once per `record`/`addExplicit`/`remove`/`upsert`/`replaceAll`). Stable
    /// across reads.
    public func generation() -> Int {
        generationCounter
    }

    private func persist(mutate: (inout DictionaryDocument) -> Void) throws {
        ensureLoaded()
        mutate(&document)
        document.schemaVersion = DictionaryDocument.currentSchemaVersion
        document.entries = document.entries.map { PromotionPolicy.withPromotion($0, promoteMin: config.promoteMin) }
        document.entries = MRUEviction.evict(document.entries, cap: document.hardCap)
        generationCounter += 1
        try writer.write(try DictionaryCodec.encode(document), to: fileURL)
    }

    private func ensureLoaded() {
        if !didLoad {
            load()
        }
    }

    /// Finds the entry whose `correctTerm` matches `term` case-insensitively and
    /// mutates it in place, or appends a freshly built entry when none matches.
    private func upsertByCorrectTerm(
        _ term: String,
        in document: inout DictionaryDocument,
        ifFound mutate: (inout DictionaryEntry) -> Void,
        ifNotFound makeNew: () -> DictionaryEntry
    ) {
        if let index = document.entries.firstIndex(where: {
            $0.correctTerm.caseInsensitiveCompare(term) == .orderedSame
        }) {
            mutate(&document.entries[index])
        } else {
            document.entries.append(makeNew())
        }
    }
}

extension DictionaryStore: DictionaryRecording {}
