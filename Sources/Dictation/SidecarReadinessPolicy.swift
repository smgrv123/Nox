import Foundation
import LLMRuntime

/// What the sidecar is doing right now, as far as dictation cares.
public enum SidecarReadiness: Equatable, Sendable {
    case ready
    case launching
    case unavailable
}

/// What dictation should do about it.
public enum SidecarWaitDecision: Equatable, Sendable {
    case proceed
    case waitUpTo(TimeInterval)
    case insertRaw
}

/// Maps sidecar readiness to a dictation action.
///
/// Readiness used to be a single `Bool`, which collapsed two very different situations:
/// a sidecar that is milliseconds from serving, and one that is not running at all. Both
/// produced a raw insert, so cleanup appeared to fire at random. Splitting `.launching`
/// out lets dictation wait briefly for the first case and give up immediately on the
/// second.
public enum SidecarReadinessPolicy {
    /// How long dictation may block on a *launching* sidecar before inserting raw.
    ///
    /// A product decision, not a measured threshold. Loading the ~4.7GB model takes far
    /// longer than any wait a user would tolerate mid-dictation, so this can never rescue
    /// a cold start — it only catches a launch that was already nearly finished when the
    /// utterance ended. Longer would leave the user watching the overlay for a payoff that
    /// is not coming; shorter would never catch anything. Revisit only with timing data
    /// from `DictationHistoryEntry.model_load_ms`.
    public static let launchWaitDeadline: TimeInterval = 2

    /// Decide what dictation should do given the current sidecar readiness.
    public static func decide(_ readiness: SidecarReadiness) -> SidecarWaitDecision {
        switch readiness {
        case .ready:
            return .proceed
        case .launching:
            return .waitUpTo(launchWaitDeadline)
        case .unavailable:
            return .insertRaw
        }
    }

    /// Maps the sidecar's actual lifecycle state to the dictation-facing readiness.
    ///
    /// `.unhealthy` and `.failed` collapse to `.unavailable` alongside `.stopped`: dictation
    /// cannot use any of the three (there is no live endpoint to call), and must not wait on
    /// them — `.unhealthy`'s backoff and `.failed`'s manual-retry recovery are both far longer
    /// than a user will tolerate mid-dictation. Only `.ready` and `.launching` are worth
    /// distinguishing here. No `default:` — a new `SidecarState` case must fail this build
    /// rather than silently falling into `.unavailable`.
    public static func readiness(for state: SidecarState) -> SidecarReadiness {
        switch state {
        case .ready:
            return .ready
        case .launching:
            return .launching
        case .stopped, .unhealthy, .failed:
            return .unavailable
        }
    }
}
