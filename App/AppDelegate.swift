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
    }
}
