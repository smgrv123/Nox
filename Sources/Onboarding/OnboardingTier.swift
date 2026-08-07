import Foundation

/// A minimal RAM-based model-tier proposal (Phase 10; User Story 17). This is
/// **not** the model subsystem — P2's `ModelManager` owns the real
/// `settings.model_tier` block (detected/override/model IDs/idle-unload seconds;
/// docs/05-lld.md §2.5) and the actual resumable model download. P1 only needs
/// enough to drive the onboarding tier-confirm screen and hand off a labelled
/// "coming in P2" placeholder where the real download will eventually run.
public enum OnboardingTier: String, CaseIterable, Sendable, Equatable, Codable {
    case tier8GB = "8gb"
    case tier16GB = "16gb"

    /// The RAM threshold docs/06-walkthrough.md §2.1 uses: "RAM is read via sysctl;
    /// ≥16GB proposes Tier: 16GB."
    private static let sixteenGBInBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024

    /// Propose a tier from detected physical RAM. Pure — the caller reads
    /// `ProcessInfo.processInfo.physicalMemory` (the effectful part; an App-layer
    /// concern) and passes the byte count in, so this stays deterministic to test.
    public static func propose(physicalMemoryBytes: UInt64) -> OnboardingTier {
        physicalMemoryBytes >= sixteenGBInBytes ? .tier16GB : .tier8GB
    }

    /// Human-readable label for the tier-confirm screen.
    public var displayName: String {
        switch self {
        case .tier8GB: return "8 GB"
        case .tier16GB: return "16 GB"
        }
    }
}
