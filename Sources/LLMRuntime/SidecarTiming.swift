import Foundation

/// Injectable elapsed-time + delay seam for the effectful engine
/// (`SidecarLifecycleController`) — the "no real sleeps in tests" half of the Phase 2
/// acceptance criteria. `SystemSidecarTiming` is what production (`SidecarManager`)
/// injects; the headless suite injects a fake virtual clock, so backoff/health-poll
/// waits never actually delay the test run.
public protocol SidecarTiming: Sendable {
    /// The current time, for computing "time since last healthy".
    func now() -> Date
    /// Suspend for `duration` seconds (a backoff or poll-interval wait). Real time in
    /// production; a fake conformer can advance a virtual clock instead of sleeping.
    func wait(for duration: TimeInterval) async
}

/// The real, wall-clock conformer (`Date()` + `Task.sleep`) — what `SidecarManager`
/// (App/) injects into production's `SidecarLifecycleController`.
public struct SystemSidecarTiming: SidecarTiming {
    public init() {}

    public func now() -> Date { Date() }

    public func wait(for duration: TimeInterval) async {
        try? await Task.sleep(for: .seconds(duration))
    }
}
