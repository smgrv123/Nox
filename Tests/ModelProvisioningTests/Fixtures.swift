import Foundation

@testable import ModelProvisioning

extension ModelDescriptor {
    /// A **real** descriptor built from the already-pinned `ggml-base.en.bin` values in
    /// `docs/native-deps.md` (the Phase 1 spike/test model). Used to prove the descriptor
    /// type and the streamed-hash verification path carry genuine production pins — never
    /// to hash a multi-GB file in the headless gate (fixture bytes cover that).
    static let baseEnFixture = ModelDescriptor(
        repo: "ggerganov/whisper.cpp",
        pinnedRevision: "306c88f4d1286aec1bf96e544632897886af5501",  // whisper.cpp v1.9.2
        filename: "ggml-base.en.bin",
        expectedSHA256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        byteSize: 147_964_211,  // on-disk size of ggml-base.en.bin (~148 MB, docs/native-deps.md)
        onDiskRelativePath: "ggml-base.en.bin")
}
