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

        /// Human-readable label for the onboarding tier-confirm screen (Phase 5's
        /// `OnboardingTierStep` reads this directly now that it drives real provisioning,
        /// rather than the P1 placeholder `Onboarding.OnboardingTier.displayName`).
        public var displayName: String {
            switch self {
            case .tier8GB: return "8 GB"
            case .tier16GB: return "16 GB"
            }
        }
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
    /// The `ggerganov/whisper.cpp` HF revision both production descriptors below are pinned
    /// to (docs/native-deps.md — obtained from the HF tree API without downloading either
    /// multi-GB blob; cross-checked against the `resolve` endpoint's `X-Repo-Commit`).
    private static let productionRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    /// 16GB-tier Whisper model (docs/04-hld.md §4.3; Phase 5 — real pin, replacing the
    /// Phase 4 placeholder). SHA-256/size are the HF tree API's `lfs.oid`/`lfs.size` for
    /// `ggml-large-v3-turbo.bin` at `productionRevision` (docs/native-deps.md).
    public static let whisperLargeV3Turbo = ModelDescriptor(
        repo: "ggerganov/whisper.cpp",
        pinnedRevision: productionRevision,
        filename: "ggml-large-v3-turbo.bin",
        expectedSHA256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        byteSize: 1_624_555_275,
        onDiskRelativePath: "ggml-large-v3-turbo.bin")

    /// 8GB-tier Whisper model — the locked **multilingual** small variant (docs/04-hld.md
    /// §4.3; NOT `.en` — required for `.auto` Hindi / code-mixed detection, User Story 4).
    /// SHA-256/size are the HF tree API's `lfs.oid`/`lfs.size` for `ggml-small.bin` at
    /// `productionRevision` (docs/native-deps.md).
    public static let whisperSmall = ModelDescriptor(
        repo: "ggerganov/whisper.cpp",
        pinnedRevision: productionRevision,
        filename: "ggml-small.bin",
        expectedSHA256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
        byteSize: 487_601_967,
        onDiskRelativePath: "ggml-small.bin")
}
