import CommandRouter

/// DI seam for the Command Dispatcher (docs/05-lld.md §3.1).
///
/// `whisperAvgLogprob` is accepted for Phase 7 calibration; Pre-Gate already
/// ran upstream, so dispatch does not re-gate on it.
public protocol Dispatching: Sendable {
    func dispatch(_ intent: RoutedIntent, whisperAvgLogprob: Float) async -> DispatchOutcome
}
