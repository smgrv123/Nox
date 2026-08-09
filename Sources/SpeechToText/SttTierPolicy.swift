import Foundation
import ModelProvisioning

/// The **real** RAM → Tier → Whisper-model mapping (docs/04-hld.md §4.3, docs/05-lld.md
/// §4.3; User Story 18). This is what the P1 onboarding placeholder
/// (`Onboarding/OnboardingTier.swift`) deferred to P2: given detected physical RAM (or the
/// user's onboarding override), pick the Whisper `ModelDescriptor` the machine can run.
///
/// Pure and injected — the caller reads `ProcessInfo.processInfo.physicalMemory` (the
/// effectful part) and passes the byte count in, so the policy is deterministic to test.
public enum SttTierPolicy {

    /// The residency tier (docs/04-hld.md §4.3). Only the two shipped tiers exist.
    public enum Tier: String, Equatable, Sendable, CaseIterable {
        /// RAM 8GB (or override): the locked small/medium Whisper variant.
        case tier8GB = "8gb"
        /// RAM ≥ 16GB (or override): Whisper large-v3-turbo.
        case tier16GB = "16gb"
    }

    /// ≥ this proposes the 16GB Tier (docs/06-walkthrough.md §2.1: "RAM is read via
    /// sysctl; ≥16GB proposes Tier: 16GB"). Hardware fact, not a calibration threshold.
    static let sixteenGBInBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024

    /// Resolve the Tier from detected RAM, or the onboarding `override` when present.
    /// **The override always wins** over detected RAM (User Story 18).
    public static func tier(physicalMemoryBytes: UInt64, override: Tier? = nil) -> Tier {
        if let override { return override }
        return physicalMemoryBytes >= sixteenGBInBytes ? .tier16GB : .tier8GB
    }

    /// The Whisper `ModelDescriptor` for a Tier.
    public static func whisperModel(for tier: Tier) -> ModelDescriptor {
        switch tier {
        case .tier16GB: return .whisperLargeV3Turbo
        case .tier8GB: return .whisperSmall
        }
    }

    /// Convenience: detected RAM (+ optional override) straight to the `ModelDescriptor`.
    public static func whisperModel(physicalMemoryBytes: UInt64, override: Tier? = nil) -> ModelDescriptor {
        whisperModel(for: tier(physicalMemoryBytes: physicalMemoryBytes, override: override))
    }
}

extension ModelDescriptor {
    /// 16GB-tier Whisper model (docs/04-hld.md §4.3).
    ///
    /// TODO(P5): pin `pinnedRevision` / `expectedSHA256` / `byteSize` when the real
    /// resumable download lands. Placeholder values are deliberately **unpinned** so
    /// `ModelVerification` fails closed against them until the pin exists.
    public static let whisperLargeV3Turbo = ModelDescriptor(
        repo: "ggerganov/whisper.cpp",
        pinnedRevision: "",
        filename: "ggml-large-v3-turbo.bin",
        expectedSHA256: "",
        byteSize: 0,
        onDiskRelativePath: "ggml-large-v3-turbo.bin")

    /// 8GB-tier Whisper model — the locked small/medium variant (docs/04-hld.md §4.3; the
    /// small-vs-medium choice is a build-time calibration decision the tier treats as a
    /// parameter).
    ///
    /// TODO(P5): pin `pinnedRevision` / `expectedSHA256` / `byteSize` when the real
    /// download lands. Unpinned until then, so verification fails closed.
    public static let whisperSmall = ModelDescriptor(
        repo: "ggerganov/whisper.cpp",
        pinnedRevision: "",
        filename: "ggml-small.bin",
        expectedSHA256: "",
        byteSize: 0,
        onDiskRelativePath: "ggml-small.bin")
}
