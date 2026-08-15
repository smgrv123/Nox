import Foundation

/// The Sidecar lifecycle state (docs/05-lld.md §3.4/§5.1 — normative; plan Phase 2;
/// User Stories 6, 7, 8, 9). Exactly the five cases the LLD's `SidecarController`
/// protocol and the §5.1 `stateDiagram-v2` name — nothing added, nothing renamed.
///
/// ```
///        startIfNeeded             /health OK
/// stopped ----------> launching -----------------> ready(port:)
///           ^                 \                          |
///           |  backoff elapsed \  launch fails/timeout    | health fails/refused
///           |                   v                         v
///           |             unhealthy(retryIn:) <-----------+
///           |                   |
///           |  stop()           | max retries exceeded
///           +-------------------+----------------> failed(reason:)
/// ```
/// `stop()` reaches `.stopped` from any state; a manual `restart()` recovers from
/// `.failed` (docs/05-lld.md §5.1: `Failed --> Launching: manual retry / next request`).
public enum SidecarState: Equatable, Sendable {
    /// No process running: nothing has been requested yet, or `stop()` was called.
    case stopped
    /// `startIfNeeded`/a backoff-elapsed retry just fired: process spawn + health-poll
    /// are in flight.
    case launching
    /// The health check passed; `port` is the live, dynamically-assigned loopback port.
    case ready(port: Int)
    /// A health check failed or the connection was refused; `retryIn` is the backoff
    /// delay (docs/05-lld.md §3.4: `1s, 2s, 4s, 8s, capped 30s`) before the next
    /// `.launching` attempt.
    case unhealthy(retryIn: TimeInterval)
    /// The backoff schedule's max-retry budget is exhausted. Only a manual `restart()`
    /// (or a fresh `startIfNeeded`) leaves this state.
    case failed(reason: String)
}
