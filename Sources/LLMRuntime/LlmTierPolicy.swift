import Foundation
import ModelProvisioning

/// The **real** RAM → Tier → Qwen-model mapping (docs/04-hld.md §4.3; User Stories 15,
/// 20, 22). Mirrors `SpeechToText.SttTierPolicy.whisperModel(for:)` exactly, but for the
/// LLM half of the same HLD §4.3 Tier row (a Whisper model and a Qwen model hang off the
/// same RAM boundary, which is why `Tier` itself now lives in the shared
/// `ModelProvisioning` module rather than being duplicated per vertical).
///
/// Pure and injected — the caller reads `ProcessInfo.processInfo.physicalMemory` (the
/// effectful part) and passes the byte count in, so the policy is deterministic to test.
public enum LlmTierPolicy {

    /// The Qwen `ModelDescriptor` for a Tier.
    public static func qwenModel(for tier: Tier) -> ModelDescriptor {
        switch tier {
        case .tier16GB: return .qwen38B
        case .tier8GB: return .qwen34B
        }
    }

    /// Convenience: detected RAM (+ optional override) straight to the `ModelDescriptor`.
    public static func qwenModel(physicalMemoryBytes: UInt64, override: Tier? = nil) -> ModelDescriptor {
        qwenModel(for: TierPolicy.tier(physicalMemoryBytes: physicalMemoryBytes, override: override))
    }
}

extension ModelDescriptor {
    /// 16GB-tier Qwen model (docs/04-hld.md §4.3; P2b Phase 4). The official `Qwen`
    /// HF-org GGUF repo's pinned revision + the HF tree API's `lfs.oid`/`lfs.size` for
    /// `Qwen3-8B-Q4_K_M.gguf`, cross-checked against the `resolve` endpoint's
    /// `X-Linked-ETag`/`X-Linked-Size`/`X-Repo-Commit` headers (docs/native-deps.md).
    public static let qwen38B = ModelDescriptor(
        repo: "Qwen/Qwen3-8B-GGUF",
        pinnedRevision: "7c41481f57cb95916b40956ab2f0b139b296d974",
        filename: "Qwen3-8B-Q4_K_M.gguf",
        expectedSHA256: "d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785",
        byteSize: 5_027_783_488,
        onDiskRelativePath: "Qwen3-8B-Q4_K_M.gguf")

    /// 8GB-tier Qwen model (docs/04-hld.md §4.3; P2b Phase 4). Same provenance method as
    /// above, against the official `Qwen/Qwen3-4B-GGUF` repo (docs/native-deps.md).
    public static let qwen34B = ModelDescriptor(
        repo: "Qwen/Qwen3-4B-GGUF",
        pinnedRevision: "bc640142c66e1fdd12af0bd68f40445458f3869b",
        filename: "Qwen3-4B-Q4_K_M.gguf",
        expectedSHA256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
        byteSize: 2_497_280_256,
        onDiskRelativePath: "Qwen3-4B-Q4_K_M.gguf")
}
