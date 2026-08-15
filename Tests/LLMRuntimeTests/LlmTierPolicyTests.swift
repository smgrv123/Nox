import ModelProvisioning
import XCTest

@testable import LLMRuntime

/// `LlmTierPolicy` maps detected RAM (or the onboarding override) to a Tier and then to
/// the Tier-appropriate Qwen `ModelDescriptor` (docs/04-hld.md §4.3; User Stories 15, 20,
/// 22). Mirrors `SttTierPolicy.whisperModel(for:)` exactly, but for the LLM half of the
/// same HLD §4.3 Tier row.
final class LlmTierPolicyTests: XCTestCase {

    private let sixteenGiB: UInt64 = 16 * 1_024 * 1_024 * 1_024

    // MARK: - RAM boundaries → Tier → Qwen ModelDescriptor

    func testAtTheBoundaryChoosesThe16GBModel() {
        XCTAssertEqual(LlmTierPolicy.qwenModel(physicalMemoryBytes: sixteenGiB), .qwen38B)
    }

    func testJustBelowTheBoundaryChoosesThe8GBModel() {
        XCTAssertEqual(LlmTierPolicy.qwenModel(physicalMemoryBytes: sixteenGiB - 1), .qwen34B)
    }

    func testWellAboveTheBoundaryChoosesThe16GBModel() {
        let thirtyTwoGiB = sixteenGiB * 2
        XCTAssertEqual(LlmTierPolicy.qwenModel(physicalMemoryBytes: thirtyTwoGiB), .qwen38B)
    }

    // MARK: - Onboarding override wins over detected RAM, both directions

    func testOverrideDownToThe8GBModelBeatsAmpleRAM() {
        let descriptor = LlmTierPolicy.qwenModel(physicalMemoryBytes: sixteenGiB * 4, override: .tier8GB)
        XCTAssertEqual(descriptor, .qwen34B)
    }

    func testOverrideUpToThe16GBModelBeatsScarceRAM() {
        let descriptor = LlmTierPolicy.qwenModel(physicalMemoryBytes: sixteenGiB / 2, override: .tier16GB)
        XCTAssertEqual(descriptor, .qwen38B)
    }

    // MARK: - The two Qwen models are distinct

    func testTheTwoTiersMapToDifferentModels() {
        XCTAssertNotEqual(
            LlmTierPolicy.qwenModel(for: .tier8GB),
            LlmTierPolicy.qwenModel(for: .tier16GB))
    }

    // MARK: - Production descriptors are pinned (no TODO placeholders)

    /// Both production Qwen descriptors must carry a real SHA-256 + byte size
    /// (docs/native-deps.md) — `ModelVerification` fails closed on an unpinned descriptor.
    func testProductionDescriptorsArePinned() {
        XCTAssertTrue(ModelDescriptor.qwen38B.isPinned)
        XCTAssertTrue(ModelDescriptor.qwen34B.isPinned)
    }

    func testQwen38BPinMatchesHuggingFaceMetadata() {
        // Obtained from the HF tree API (`lfs.oid`/`lfs.size`) and cross-checked against the
        // `resolve` endpoint's `X-Linked-ETag`/`X-Linked-Size`/`X-Repo-Commit` headers — no
        // multi-GB download performed (docs/native-deps.md).
        let sut = ModelDescriptor.qwen38B
        XCTAssertEqual(sut.repo, "Qwen/Qwen3-8B-GGUF")
        XCTAssertEqual(sut.filename, "Qwen3-8B-Q4_K_M.gguf")
        XCTAssertEqual(sut.pinnedRevision, "7c41481f57cb95916b40956ab2f0b139b296d974")
        XCTAssertEqual(sut.expectedSHA256, "d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785")
        XCTAssertEqual(sut.byteSize, 5_027_783_488)
    }

    func testQwen34BPinMatchesHuggingFaceMetadata() {
        let sut = ModelDescriptor.qwen34B
        XCTAssertEqual(sut.repo, "Qwen/Qwen3-4B-GGUF")
        XCTAssertEqual(sut.filename, "Qwen3-4B-Q4_K_M.gguf")
        XCTAssertEqual(sut.pinnedRevision, "bc640142c66e1fdd12af0bd68f40445458f3869b")
        XCTAssertEqual(sut.expectedSHA256, "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5")
        XCTAssertEqual(sut.byteSize, 2_497_280_256)
    }

    func testTheTwoQwenModelsArePinnedToDifferentRepos() {
        // Unlike the Whisper pair (one repo, one shared revision), the two Qwen
        // quantizations are published in two separate official Qwen GGUF repos.
        XCTAssertNotEqual(ModelDescriptor.qwen38B.repo, ModelDescriptor.qwen34B.repo)
    }
}
