import ModelProvisioning
import XCTest

@testable import SpeechToText

/// `SttTierPolicy` maps detected RAM (or the onboarding override) to a Tier and then to
/// the Tier-appropriate Whisper `ModelDescriptor` (docs/04-hld.md §4.3; User Story 18).
/// This is the **real** tier→model mapping the P1 onboarding placeholder deferred to P2.
final class SttTierPolicyTests: XCTestCase {

    /// The RAM boundary under test, stated once here (docs/04-hld.md §4.3: RAM ≥ 16GB ⇒
    /// the 16GB Tier). Asserting descriptor *identity* against the policy's own statics
    /// keeps placeholder pin values out of the assertions.
    private let sixteenGiB: UInt64 = 16 * 1_024 * 1_024 * 1_024

    // MARK: - RAM boundaries → Tier → ModelDescriptor

    func testAtTheBoundaryChoosesThe16GBModel() {
        XCTAssertEqual(SttTierPolicy.tier(physicalMemoryBytes: sixteenGiB), .tier16GB)
        XCTAssertEqual(SttTierPolicy.whisperModel(physicalMemoryBytes: sixteenGiB), .whisperLargeV3Turbo)
    }

    func testJustBelowTheBoundaryChoosesThe8GBModel() {
        XCTAssertEqual(SttTierPolicy.tier(physicalMemoryBytes: sixteenGiB - 1), .tier8GB)
        XCTAssertEqual(SttTierPolicy.whisperModel(physicalMemoryBytes: sixteenGiB - 1), .whisperSmall)
    }

    func testWellAboveTheBoundaryChoosesThe16GBModel() {
        let thirtyTwoGiB = sixteenGiB * 2
        XCTAssertEqual(SttTierPolicy.tier(physicalMemoryBytes: thirtyTwoGiB), .tier16GB)
        XCTAssertEqual(SttTierPolicy.whisperModel(physicalMemoryBytes: thirtyTwoGiB), .whisperLargeV3Turbo)
    }

    // MARK: - Onboarding override wins over detected RAM

    func testOverrideDownToThe8GBModelBeatsAmpleRAM() {
        let descriptor = SttTierPolicy.whisperModel(physicalMemoryBytes: sixteenGiB * 4, override: .tier8GB)
        XCTAssertEqual(descriptor, .whisperSmall)
    }

    func testOverrideUpToThe16GBModelBeatsScarceRAM() {
        let descriptor = SttTierPolicy.whisperModel(physicalMemoryBytes: sixteenGiB / 2, override: .tier16GB)
        XCTAssertEqual(descriptor, .whisperLargeV3Turbo)
    }

    // MARK: - The two Whisper models are distinct

    func testTheTwoTiersMapToDifferentModels() {
        XCTAssertNotEqual(
            SttTierPolicy.whisperModel(for: .tier8GB),
            SttTierPolicy.whisperModel(for: .tier16GB))
    }

    // MARK: - Phase 5: production descriptors are pinned (no more TODO placeholders)

    /// Both production Whisper descriptors must carry a real SHA-256 + byte size (docs/native-deps.md)
    /// — `ModelVerification` fails closed on an unpinned descriptor, so an un-pinned production
    /// model could never be downloaded/verified. This is the direct proof the Phase 4 placeholders
    /// were replaced, not just renamed.
    func testProductionDescriptorsArePinned() {
        XCTAssertTrue(ModelDescriptor.whisperLargeV3Turbo.isPinned)
        XCTAssertTrue(ModelDescriptor.whisperSmall.isPinned)
    }

    func testLargeV3TurboPinMatchesHuggingFaceMetadata() {
        // Obtained from the HF tree API (`lfs.oid`/`lfs.size`) and cross-checked against the
        // `resolve` endpoint's `X-Linked-ETag`/`X-Linked-Size`/`X-Repo-Commit` headers — no
        // multi-GB download performed (docs/native-deps.md).
        let sut = ModelDescriptor.whisperLargeV3Turbo
        XCTAssertEqual(sut.repo, "ggerganov/whisper.cpp")
        XCTAssertEqual(sut.filename, "ggml-large-v3-turbo.bin")
        XCTAssertEqual(sut.pinnedRevision, "5359861c739e955e79d9a303bcbc70fb988958b1")
        XCTAssertEqual(sut.expectedSHA256, "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
        XCTAssertEqual(sut.byteSize, 1_624_555_275)
    }

    func testSmallPinMatchesHuggingFaceMetadataAndIsMultilingual() {
        // The **multilingual** small variant (`ggml-small.bin`, not `.en`) — required for
        // `.auto` Hindi / code-mixed detection (User Story 4, docs/04-hld.md §4.3 footnote).
        let sut = ModelDescriptor.whisperSmall
        XCTAssertEqual(sut.repo, "ggerganov/whisper.cpp")
        XCTAssertEqual(sut.filename, "ggml-small.bin")
        XCTAssertFalse(sut.filename.contains(".en"), "must be the multilingual variant, not small.en")
        XCTAssertEqual(sut.pinnedRevision, "5359861c739e955e79d9a303bcbc70fb988958b1")
        XCTAssertEqual(sut.expectedSHA256, "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b")
        XCTAssertEqual(sut.byteSize, 487_601_967)
    }

    func testBothProductionModelsArePinnedToTheSameRevision() {
        // Both files were pinned from the same HF tree snapshot — a byte-reproducible pair.
        XCTAssertEqual(ModelDescriptor.whisperLargeV3Turbo.pinnedRevision, ModelDescriptor.whisperSmall.pinnedRevision)
    }

    // MARK: - Tier display names (Phase 5: the onboarding tier step reads this directly)

    func testTierDisplayNames() {
        XCTAssertEqual(SttTierPolicy.Tier.tier8GB.displayName, "8 GB")
        XCTAssertEqual(SttTierPolicy.Tier.tier16GB.displayName, "16 GB")
    }
}
