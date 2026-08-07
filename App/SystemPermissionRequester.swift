import AVFoundation
import CoreGraphics
import EventKit
import IOKit.hid
import Permissions

/// The effectful shell that **triggers** a permission's native grant prompt during
/// onboarding (docs/05-lld.md §8 — the "Prompt / deep-link" column). Sibling to
/// `SystemPermissionReader`, which only *reads* status prompt-free (User Story 27).
///
/// macOS does not list an app under System Settings → Privacy for **Microphone**, **Screen
/// Recording**, or **Calendar** until it has requested access at least once — so a deep-link
/// to those panes before a first request lands on a page that doesn't show Aide (there's
/// nothing to toggle). Onboarding therefore *requests* those directly. **Accessibility** has
/// no in-app prompt (`Permission.canRequestInApp == false`) and is handled by a Settings
/// deep-link instead (User Story 15/18). Verified by running the app, not unit-tested.
struct SystemPermissionRequester {

    /// Trigger the system grant prompt for `permission`, then call `completion` on the main
    /// thread once the user has responded (or immediately for a permission that can't be
    /// requested in-app). The completion is the reliable "the user decided" signal that
    /// onboarding uses to re-check status and auto-advance.
    func request(_ permission: Permission, completion: @escaping () -> Void) {
        switch permission {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async(execute: completion)
            }
        case .calendar:
            // Hold the store until the async callback fires (a bare temporary would
            // deallocate before the user responds).
            let store = EKEventStore()
            store.requestFullAccessToEvents { _, _ in
                _ = store
                DispatchQueue.main.async(execute: completion)
            }
        case .screenRecording:
            // Synchronous: presents the prompt (first time) and registers the app in the
            // Screen Recording list. A fresh grant can require an app relaunch to take
            // effect — the step's Re-check / next launch reflects it.
            _ = CGRequestScreenCaptureAccess()
            completion()
        case .inputMonitoring:
            // Synchronous: presents the Input Monitoring prompt (first time) and
            // registers the app in the list. A fresh grant can require an app relaunch
            // to take effect — the step's Re-check / next launch reflects it.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            completion()
        case .accessibility:
            // No in-app prompt (`Permission.canRequestInApp == false`) — the caller
            // deep-links to System Settings instead.
            completion()
        }
    }
}
