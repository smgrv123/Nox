import Foundation
import ModelProvisioning

/// The pure idle-unload state machine (docs/05-lld.md §5.4 — normative; plan Phase 6;
/// User Stories 16, 17, 18). Given `(Tier, time since last request)` → a resident/unload
/// decision: **16GB never unloads**; **8GB unloads once the idle threshold is strictly
/// exceeded** with no intervening activity. Any activity resets the idle timer (the
/// caller's responsibility — this function is stateless).
///
/// Mirrors `SidecarBackoffSchedule`'s design posture: a pure, deterministic function of
/// caller-supplied values — no `Date()`, no async, no timer, no side-effects. The real
/// timer lives in the effectful `SidecarManager` shell (`App/`), which calls this on
/// each tick to decide whether to unload.
///
/// The idle threshold defaults to 5 minutes (300s; LLD §2.5's `llm_unload_idle_seconds:
/// 600` is the full-spec default but treated as provisional/injectable per the plan's
/// "Architectural decisions" — same posture as P2a's Pre-Gate thresholds). The
/// production value is injectable at the call site so it can be tuned without recompiling.
public enum IdleUnloadPolicy {

    /// Default idle threshold: 5 minutes (PROVISIONAL — see the type's doc comment).
    public static let defaultIdleThreshold: TimeInterval = 300

    /// The outcome of an idle-unload evaluation.
    public enum Decision: Equatable, Sendable {
        /// The LLM should stay loaded in RAM.
        case resident
        /// The LLM should be unloaded to reclaim RAM (8GB tier only).
        case unload
    }

    /// Evaluate whether the Sidecar's LLM should stay resident or be unloaded.
    ///
    /// - Parameters:
    ///   - tier: the confirmed model tier (`tier16GB` stays resident unconditionally).
    ///   - idleInterval: seconds since the last LLM request completed (caller-computed;
    ///     activity resets this to 0 at the call site, not inside this function).
    ///   - threshold: the idle duration that must be **strictly exceeded** before 8GB
    ///     triggers an unload (defaults to `defaultIdleThreshold`).
    /// - Returns: `.resident` or `.unload`.
    public static func decide(
        tier: Tier,
        idleInterval: TimeInterval,
        threshold: TimeInterval = defaultIdleThreshold
    ) -> Decision {
        switch tier {
        case .tier16GB:
            return .resident
        case .tier8GB:
            return idleInterval > threshold ? .unload : .resident
        }
    }
}
