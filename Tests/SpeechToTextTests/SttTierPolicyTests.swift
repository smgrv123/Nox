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
}
