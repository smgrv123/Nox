import AppKit

/// Observes system sleep/wake notifications and forwards the two edges via callbacks
/// (PHASE 11; User Story 37). Extracted from `AppCoordinator`, which owned this pair
/// of `NSWorkspace` observers inline — install-two-observers-then-tear-them-down-in-
/// `deinit` is a small, self-contained responsibility that doesn't need to live on the
/// app shell itself.
///
/// Both observers are installed immediately on `init` and removed automatically in
/// `deinit`, so a caller only needs to retain the instance for as long as it wants to
/// keep observing — no separate start/stop calls. Notifications are delivered on
/// `.main`, matching `NSWorkspace`'s queue.
final class SleepWakeObserver {

    private let center = NSWorkspace.shared.notificationCenter
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - onSleep: called when the system is about to sleep.
    ///   - onWake: called when the system wakes.
    init(onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in onSleep() }
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in onWake() }
        observers = [sleep, wake]
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
