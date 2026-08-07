import AppKit
import SwiftUI

/// The first-run Onboarding window (Phase 10; User Stories 16–24): an ordinary,
/// focus-taking `NSWindow` — the opposite of the non-activating Overlay — hosting
/// the SwiftUI walkthrough. `AppCoordinator` owns one instance and shows/hides it as
/// `onboardingFlow` starts/completes.
///
/// This mirrors `ConfirmationModal`'s mechanism: an imperative AppKit window shown
/// outside the `MenuBarExtra`/Settings `Scene` graph, rather than a SwiftUI `Window`
/// scene — the established idiom in this app for chrome that isn't the menubar menu
/// or the Settings panes. No close button: the walkthrough is a first-run gate, left
/// only by finishing it (`AppCoordinator.completeOnboarding`) or quitting the app
/// (already available from the menubar), matching how `ConfirmationModal` also has
/// no close button (its two explicit buttons are the only way out).
final class OnboardingWindow {
    private var window: NSWindow?

    /// Show the window, creating it once and re-using it for the rest of this run.
    /// `coordinator` is bound via `@ObservedObject` in the hosted root view, so the
    /// window's content re-renders automatically as `onboardingFlow` advances —
    /// nothing here needs to be told about individual step changes.
    func show(coordinator: AppCoordinator) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = OnboardingRootView(coordinator: coordinator)
        let created = NSWindow(contentViewController: NSHostingController(rootView: view))
        created.styleMask = [.titled]
        created.title = "Welcome to Aide"
        created.isReleasedWhenClosed = false
        created.center()
        window = created

        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }

    /// Close and release the current window, if any (called once onboarding completes).
    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}
