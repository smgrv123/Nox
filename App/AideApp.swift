import AideCore
import SwiftUI

/// Menubar-only entry point (no Dock icon — `LSUIElement` is set in project.yml).
///
/// This is the tracer-bullet app shell described in the project README: it proves
/// the hardest-to-set-up pieces work together — a signed `.app` bundle, a menubar
/// presence via `MenuBarExtra`, and the global hotkey tap — before any real feature
/// is built on top. See docs/04-hld.md §13 (Overlay & Menubar UI Subsystem).
@main
struct AideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Aide", systemImage: "waveform") {
            Text("Aide v\(Build.version)")
                .font(.headline)
            Text(appDelegate.hotkeyStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Open Accessibility Settings…") {
                AppDelegate.openAccessibilitySettings()
            }
            Divider()
            Button("Quit Aide") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
