import XCTest

@testable import ModelProvisioning

/// `Tier` + `TierPolicy` — the shared RAM-boundary concept both P2a (Whisper) and P2b
/// (Qwen) tier a model off (docs/04-hld.md §4.3). Moved here from
/// `SpeechToText.SttTierPolicy` in P2b Phase 4: HLD §4.3's Tier→model table ties a
/// Whisper model **and** a Qwen model to the same RAM row, so keeping two independent
/// copies of the boundary logic was a duplication/drift risk. Carries forward
/// `SttTierPolicyTests`' RAM-boundary coverage unchanged in intent (docs/native-deps.md).
final class TierPolicyTests: XCTestCase {

    private let sixteenGiB: UInt64 = 16 * 1_024 * 1_024 * 1_024

    // MARK: - RAM boundaries → Tier

    func testAtTheBoundaryChoosesThe16GBTier() {
        XCTAssertEqual(TierPolicy.tier(physicalMemoryBytes: sixteenGiB), .tier16GB)
    }

    func testJustBelowTheBoundaryChoosesThe8GBTier() {
        XCTAssertEqual(TierPolicy.tier(physicalMemoryBytes: sixteenGiB - 1), .tier8GB)
    }

    func testWellAboveTheBoundaryChoosesThe16GBTier() {
        XCTAssertEqual(TierPolicy.tier(physicalMemoryBytes: sixteenGiB * 2), .tier16GB)
    }

    // MARK: - Onboarding override wins over detected RAM, both directions

    func testOverrideDownToThe8GBTierBeatsAmpleRAM() {
        XCTAssertEqual(
            TierPolicy.tier(physicalMemoryBytes: sixteenGiB * 4, override: .tier8GB), .tier8GB)
    }

    func testOverrideUpToThe16GBTierBeatsScarceRAM() {
        XCTAssertEqual(
            TierPolicy.tier(physicalMemoryBytes: sixteenGiB / 2, override: .tier16GB), .tier16GB)
    }

    // MARK: - Display names (the onboarding tier-confirm screen reads this directly)

    func testTierDisplayNames() {
        XCTAssertEqual(Tier.tier8GB.displayName, "8 GB")
        XCTAssertEqual(Tier.tier16GB.displayName, "16 GB")
    }

    func testTierIsCaseIterableWithExactlyTwoCases() {
        XCTAssertEqual(Tier.allCases, [.tier8GB, .tier16GB])
    }
}
