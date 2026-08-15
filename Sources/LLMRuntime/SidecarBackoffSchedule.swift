import Foundation

/// The pure Sidecar backoff-schedule function (docs/05-lld.md §3.4; PRD "Solution";
/// plan Phase 2; User Stories 6, 7, 8, 9, 20). Given how many consecutive failures
/// have occurred and how long it's been since the Sidecar was last healthy, decides
/// the next retry delay — or signals give-up once the retry budget is exhausted.
///
/// **Locked schedule** (docs/05-lld.md §3.4): `1s, 2s, 4s, 8s, capped at 30s`; a
/// healthy interval **strictly greater than 60s** resets the attempt count back to
/// zero, so a transient blip after a long healthy run doesn't inherit a stale,
/// already-escalated delay. `maxAttempts` (the give-up threshold) is **not** specified
/// by the LLD — the PRD's "Out of Scope" names backoff calibration as provisional,
/// same posture as P2a's Pre-Gate thresholds — so it is an injectable parameter with a
/// documented default rather than a hardcoded constant.
///
/// **No real time inside this function.** `timeSinceLastHealthy` is a plain,
/// caller-computed `TimeInterval` — never a `Date` read, never a sleep — so this stays
/// a pure, deterministic function callable with zero real sleeps in its test suite.
public enum SidecarBackoffSchedule {

    /// The first retry's delay.
    public static let baseDelay: TimeInterval = 1
    /// The backoff ceiling — no retry ever waits longer than this.
    public static let capDelay: TimeInterval = 30
    /// A healthy interval strictly greater than this resets the attempt count.
    public static let healthyResetThreshold: TimeInterval = 60
    /// Default give-up threshold (provisional — see the type's doc comment). Six
    /// attempts spans `1+2+4+8+16+30 = 61s` of cumulative backoff before giving up.
    public static let defaultMaxAttempts = 6

    /// What to do next, given the failure that just happened.
    public enum Decision: Equatable, Sendable {
        /// Wait `delay` seconds, then try again; `attempt` is the 1-based count this
        /// delay corresponds to (pass it back in as `attempt` on the *next* call).
        case retry(delay: TimeInterval, attempt: Int)
        /// The retry budget is exhausted — the caller should surface `.failed`.
        case giveUp(attempts: Int)
    }

    /// - Parameters:
    ///   - attempt: consecutive failures **before** this one (`0` the first time, or
    ///     right after a reset).
    ///   - timeSinceLastHealthy: seconds since the Sidecar was last known healthy, or
    ///     `nil` if it has never been healthy. A value `> healthyResetThreshold` resets
    ///     `attempt` to `0` before computing the delay; `nil` does **not** reset (a
    ///     Sidecar that has never come up must still escalate to give-up).
    ///   - maxAttempts: the give-up threshold (see `defaultMaxAttempts`).
    public static func decide(
        attempt: Int,
        timeSinceLastHealthy: TimeInterval?,
        maxAttempts: Int = defaultMaxAttempts
    ) -> Decision {
        let resets = (timeSinceLastHealthy ?? 0) > healthyResetThreshold
        let baseAttempt = resets ? 0 : max(attempt, 0)
        let nextAttempt = baseAttempt + 1

        guard nextAttempt <= maxAttempts else {
            return .giveUp(attempts: baseAttempt)
        }
        let delay = min(baseDelay * pow(2, Double(nextAttempt - 1)), capDelay)
        return .retry(delay: delay, attempt: nextAttempt)
    }
}
