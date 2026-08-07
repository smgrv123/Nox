import XCTest

@testable import Onboarding

/// The pure RAM → proposed-Tier rule (User Story 17; docs/06-walkthrough.md §2.1:
/// "RAM is read via sysctl; ≥16GB proposes Tier: 16GB"). Deliberately minimal — P1
/// is not the model subsystem; this exists only to drive the onboarding tier-confirm
/// screen. Real `RAM` detection (`ProcessInfo.processInfo.physicalMemory`) is an
/// effectful App-layer read; this is exercised purely from injected byte counts.
final class OnboardingTierTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    func testAtLeast16GBProposesThe16GBTier() {
        XCTAssertEqual(OnboardingTier.propose(physicalMemoryBytes: 16 * oneGB), .tier16GB)
        XCTAssertEqual(OnboardingTier.propose(physicalMemoryBytes: 32 * oneGB), .tier16GB)
    }

    func testBelow16GBProposesThe8GBTier() {
        XCTAssertEqual(OnboardingTier.propose(physicalMemoryBytes: 8 * oneGB), .tier8GB)
        XCTAssertEqual(OnboardingTier.propose(physicalMemoryBytes: (16 * oneGB) - 1), .tier8GB)
    }

    func testDisplayNames() {
        XCTAssertEqual(OnboardingTier.tier8GB.displayName, "8 GB")
        XCTAssertEqual(OnboardingTier.tier16GB.displayName, "16 GB")
    }
}
