import Foundation
import ModelProvisioning

/// The pure idle-unload state machine (docs/05-lld.md §5.4 — updated to supersede the
/// prior "16GB always resident" spec per explicit product decision; plan Phase 6; User
/// Stories 16, 17, 18). Given `(Tier, time since last request)` → a resident/unload
/// decision: **both tiers unload once their own idle threshold is strictly exceeded**
/// with no intervening activity — 16GB at 3 minutes (`tier16IdleThreshold`, 180s), 8GB
/// at 5 minutes (`defaultIdleThreshold`, 300s). Any activity resets the idle timer (the
/// caller's responsibility — this function is stateless).
///
/// Mirrors `SidecarBackoffSchedule`'s design posture: a pure, deterministic function of
/// caller-supplied values — no `Date()`, no async, no timer, no side-effects. The real
/// timer lives in the effectful `SidecarManager` shell (`App/`), which calls this on
/// each tick to decide whether to unload.
///
/// The 8GB idle threshold defaults to 5 minutes (300s; LLD §2.5's
/// `llm_unload_idle_seconds: 600` is the full-spec default but treated as
/// provisional/injectable per the plan's "Architectural decisions" — same posture as
/// P2a's Pre-Gate thresholds). The 16GB idle threshold is 3 minutes (180s) — a
/// deliberate, shorter policy value since the 16GB Qwen3-8B residency costs ~4.7GB of
/// RAM held indefinitely otherwise. Both production values are injectable at the call
/// site so they can be tuned without recompiling.
public enum IdleUnloadPolicy {

    /// Default idle threshold for the 8GB tier: 5 minutes (PROVISIONAL — see the type's
    /// doc comment).
    public static let defaultIdleThreshold: TimeInterval = 300

    /// Idle threshold for the 16GB tier: 3 minutes. Shorter than the 8GB tier's default
    /// because the 16GB tier's Qwen3-8B residency (~4.7GB) is costlier to hold
    /// indefinitely — see the type's doc comment.
    public static let tier16IdleThreshold: TimeInterval = 180

    /// The outcome of an idle-unload evaluation.
    public enum Decision: Equatable, Sendable {
        /// The LLM should stay loaded in RAM.
        case resident
        /// The LLM should be unloaded to reclaim RAM.
        case unload
    }

    /// Evaluate whether the Sidecar's LLM should stay resident or be unloaded.
    ///
    /// - Parameters:
    ///   - tier: the confirmed model tier.
    ///   - idleInterval: seconds since the last LLM request completed (caller-computed;
    ///     activity resets this to 0 at the call site, not inside this function).
    ///   - threshold: the idle duration that must be **strictly exceeded** before this
    ///     tier triggers an unload — the caller supplies the tier-appropriate value
    ///     (`tier16IdleThreshold` for 16GB, `defaultIdleThreshold` for 8GB); this
    ///     parameter's own default matches the 8GB production value.
    /// - Returns: `.resident` or `.unload`.
    public static func decide(
        tier: Tier,
        idleInterval: TimeInterval,
        threshold: TimeInterval = defaultIdleThreshold
    ) -> Decision {
        idleInterval > threshold ? .unload : .resident
    }
}
