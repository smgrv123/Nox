import SwiftUI

/// Menubar-only entry point (no Dock icon — `LSUIElement` is set in project.yml).
///
/// A thin SwiftUI shell: it declares the two surfaces (the `MenuBarExtra` menu and
/// the Settings window, hosted by `SettingsRootView` — App/Settings/) and hands
/// lifecycle ownership to `AppCoordinator` via the `AppDelegate` seam. Everything
/// with behavior — single-instance, the hotkey tap, the published status — lives
/// in the coordinator, not here.
/// See docs/04-hld.md §13 (Overlay & Menubar UI Subsystem).
@main
struct AideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Aide", systemImage: "waveform") {
            MenubarMenu(coordinator: appDelegate.coordinator)
        }
        .menuBarExtraStyle(.menu)

        // PHASE 8: the Settings framework. `SettingsRootView` hosts a registered
        // list of `SettingsPane`s (App/Settings/) — Permissions today, with later
        // phases (e.g. Phase 9's hotkey/overlay options) appending more without
        // touching this scene or the host view. The coordinator is threaded through
        // so the Data pane can trigger `requestWipeAllHistory()` (Phase 11).
        Settings {
            SettingsRootView(coordinator: appDelegate.coordinator)
        }
    }
}
