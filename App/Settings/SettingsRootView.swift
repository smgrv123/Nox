import SwiftUI

/// The Settings window's root view — the "host" half of the pane-registration
/// framework (Phase 8; User Story 28). It owns nothing about any individual
/// pane's content; it only renders whatever `SettingsPane` list it's given,
/// each inside its own `.tabItem`. Registering a new pane (P9's hotkey/overlay
/// options pane, and whatever later pillars add) means appending a `SettingsPane`
/// to `panes` below — no change to the `TabView` plumbing itself.
struct SettingsRootView: View {
    @ObservedObject var coordinator: AppCoordinator

    /// The registered panes, in tab order. Phase 8 ships Permissions (User
    /// Stories 31, 32) and Data (the Phase 11 wipe action, relocated here now
    /// that panes have a real home). Phase 9 appends Hotkeys (User Stories 13, 14,
    /// 29) and Overlay & Indicators (User Story 30) — registration is purely additive,
    /// no change to the `TabView` plumbing above.
    private var panes: [SettingsPane] {
        [
            SettingsPane(id: "permissions", title: "Permissions", systemImage: "hand.raised") {
                PermissionsPane(coordinator: coordinator)
            },
            SettingsPane(id: "hotkeys", title: "Hotkeys", systemImage: "keyboard") {
                HotkeysPane(coordinator: coordinator)
            },
            SettingsPane(id: "overlay", title: "Overlay", systemImage: "rectangle.inset.filled") {
                OverlayOptionsPane(coordinator: coordinator)
            },
            SettingsPane(id: "data", title: "Data", systemImage: "trash") {
                DataPane(coordinator: coordinator)
            },
        ]
    }

    var body: some View {
        TabView {
            ForEach(panes) { pane in
                pane.content()
                    .tabItem { Label(pane.title, systemImage: pane.systemImage) }
                    .tag(pane.id)
            }
        }
        .frame(width: 480, height: 380)
    }
}
