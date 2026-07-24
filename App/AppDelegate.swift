import AppKit
import os

/// Owns the app-lifetime singletons (currently just the hotkey tap).
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let hotkeys = HotkeyManager()

    /// Human-readable hotkey state surfaced in the menubar menu.
    @Published var hotkeyStatus: String = "Starting…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeys.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.hotkeyStatus = status }
        }
        hotkeys.start()
    }

    /// Deep-link to the exact System Settings pane for the Accessibility grant.
    /// (Onboarding will drive this per docs/04-hld.md §14; exposed here for the tracer bullet.)
    static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
