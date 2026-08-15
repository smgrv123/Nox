import Foundation

/// The residency tier (docs/04-hld.md §4.3). Only the two shipped tiers exist.
///
/// **Shared by P2a (Whisper) and P2b (Qwen)** — HLD §4.3's Tier→model table ties an STT
/// model **and** an LLM model to the same RAM row, so this lives once, here, in the
/// module both verticals already depend on, rather than as two independently-drifting
/// copies (moved from `SpeechToText.SttTierPolicy` in P2b Phase 4).
public enum Tier: String, Equatable, Sendable, CaseIterable {
    /// RAM 8GB (or override): the locked small/medium Whisper variant + Qwen3-4B.
    case tier8GB = "8gb"
    /// RAM ≥ 16GB (or override): Whisper large-v3-turbo + Qwen3-8B.
    case tier16GB = "16gb"

    /// Human-readable label for the onboarding tier-confirm screen (read directly by
    /// `OnboardingTierStep` via `SttTierPolicy.Tier`, which is this type).
    public var displayName: String {
        switch self {
        case .tier8GB: return "8 GB"
        case .tier16GB: return "16 GB"
        }
    }
}

/// RAM → `Tier` resolution, shared by every per-vertical tier→model policy
/// (`SpeechToText.SttTierPolicy`, `LLMRuntime.LlmTierPolicy`) so the boundary itself is
/// defined exactly once.
public enum TierPolicy {
    /// ≥ this proposes the 16GB Tier (docs/06-walkthrough.md §2.1: "RAM is read via
    /// sysctl; ≥16GB proposes Tier: 16GB"). Hardware fact, not a calibration threshold.
    static let sixteenGBInBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024

    /// Resolve the Tier from detected RAM, or the onboarding `override` when present.
    /// **The override always wins** over detected RAM (User Story 18).
    public static func tier(physicalMemoryBytes: UInt64, override: Tier? = nil) -> Tier {
        if let override { return override }
        return physicalMemoryBytes >= sixteenGBInBytes ? .tier16GB : .tier8GB
    }
}
