import SwiftUI

/// Menubar-only entry point (no Dock icon — `LSUIElement` is set in project.yml).
///
/// A thin SwiftUI shell: it declares the two surfaces (the `MenuBarExtra` menu and
/// an empty Settings window) and hands lifecycle ownership to `AppCoordinator` via
/// the `AppDelegate` seam. Everything with behavior — single-instance, the hotkey
/// tap, the published status — lives in the coordinator, not here.
/// See docs/04-hld.md §13 (Overlay & Menubar UI Subsystem).
@main
struct AideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Aide", systemImage: "waveform") {
            MenubarMenu(coordinator: appDelegate.coordinator)
        }
        .menuBarExtraStyle(.menu)

        // Empty for now — the Settings framework + P1 panes land in later phases.
        Settings {
            SettingsView()
        }
    }
}
