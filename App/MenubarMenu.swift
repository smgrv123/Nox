import AideCore
import SwiftUI

/// The `MenuBarExtra` menu content (User Stories 3, 4): a thin SwiftUI shell that
/// renders the status `AppCoordinator` publishes and offers entries into Settings
/// and Quit. It observes the coordinator directly so live status changes (e.g. the
/// hotkey moving to "Listening…") re-render the menu. See docs/04-hld.md §13.
struct MenubarMenu: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Text("Aide v\(Build.version)")
            .font(.headline)
        Text(coordinator.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)

        Divider()

        Button("Open Accessibility Settings…") {
            AppCoordinator.openAccessibilitySettings()
        }
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        // PHASE 3 (TEMPORARY debug trigger): flips + persists the audio-cue-on-listen
        // setting so "change a setting → quit → relaunch → value restored" is manually
        // verifiable now. Replaced by the real overlay/indicator Settings pane in
        // Phase 9 (mirrors how Phase 4's state-forcing menu items are temporary).
        Toggle(
            "Audio cue on listen (debug)",
            isOn: Binding(
                get: { coordinator.settings.indicators.audioCueOnListen },
                set: { coordinator.setAudioCueOnListen($0) }))

        Divider()

        Button("Quit Aide") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
