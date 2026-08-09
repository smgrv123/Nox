import Foundation

/// The pinned identity of a downloadable model blob (docs/05-lld.md §2.7; User Stories
/// 12/14/18). Everything the provisioning core needs to fetch a model, verify it, and
/// place it on disk — and nothing effectful. Shared by P2a (Whisper) and P2b (the LLM
/// GGUF), so it carries no STT/LLM specifics.
///
/// - `repo` / `pinnedRevision`: the source repo and the immutable commit/revision it is
///   pinned to, so a re-download is byte-reproducible and can't drift under us.
/// - `expectedSHA256`: lowercase hex of the whole file; the integrity oracle
///   `ModelVerification` checks against. An empty value marks an **unpinned** descriptor
///   (a placeholder awaiting a real pin) — such a descriptor can never verify a blob.
/// - `byteSize`: the exact on-disk size; the resume math and the size half of verification
///   both key off it.
/// - `onDiskRelativePath`: where the blob lives **relative to the models directory**
///   (`ModelsDirectory` resolves the absolute URL), so the descriptor stays location-free.
public struct ModelDescriptor: Equatable, Sendable {
    public let repo: String
    public let pinnedRevision: String
    public let filename: String
    public let expectedSHA256: String
    public let byteSize: Int64
    public let onDiskRelativePath: String

    public init(
        repo: String,
        pinnedRevision: String,
        filename: String,
        expectedSHA256: String,
        byteSize: Int64,
        onDiskRelativePath: String
    ) {
        self.repo = repo
        self.pinnedRevision = pinnedRevision
        self.filename = filename
        self.expectedSHA256 = expectedSHA256
        self.byteSize = byteSize
        self.onDiskRelativePath = onDiskRelativePath
    }

    /// True once the descriptor carries a real SHA-256 and a positive size — i.e. it is
    /// safe to verify a blob against. Placeholder descriptors (SHA/size pinned in a later
    /// phase) are **not** pinned and must never yield a `verified`.
    public var isPinned: Bool {
        !expectedSHA256.isEmpty && byteSize > 0
    }
}
