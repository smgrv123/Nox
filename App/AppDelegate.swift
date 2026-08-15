import AppKit

/// Thin `NSApplicationDelegate` adapter. It owns no lifecycle state itself —
/// every launch hook is forwarded to `AppCoordinator`, the single lifecycle owner
/// (specs/P1 §"AppCoordinator"). It exists only because `MenuBarExtra` needs an
/// app-delegate seam for the launch hooks plus a stable object the menubar view
/// can observe.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The lifecycle owner. Created eagerly so it exists before the first scene
    /// build — the menubar menu observes `coordinator.statusText`.
    let coordinator = AppCoordinator()

    /// Single-instance enforcement runs here (earliest hook) so a duplicate stands
    /// down before it can register a second menubar item or hotkey tap.
    func applicationWillFinishLaunching(_ notification: Notification) {
        coordinator.applicationWillFinishLaunching()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.applicationDidFinishLaunching()
        // P2b Phase 2 (`AppCoordinator+Sidecar.swift`) — opt-in, manual-verification-only.
        coordinator.runSidecarCheckIfRequested()
    }

    /// PHASE 10 (User Story 20): the moment the user switches back to Aide — e.g.
    /// after granting a permission in System Settings — re-check the onboarding
    /// flow's current permission step so it auto-advances without waiting for the
    /// poll timer.
    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator.applicationDidBecomeActive()
    }

    /// P2b Phase 2 (User Story 9): give the Sidecar's async teardown a chance to kill
    /// its `llama-server` child before the app actually exits — `.terminateLater`
    /// is the only way to await cleanup from this synchronous delegate callback.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator.applicationShouldTerminate { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
