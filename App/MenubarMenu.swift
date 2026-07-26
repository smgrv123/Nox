import AideCore
import Overlay
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

        // P7 fix-it (User Stories 15, 26): when the hotkey path is blocked by a missing
        // Accessibility grant, PermissionGate supplies the hint + exact-pane deep-link.
        // Shown only while the grant is missing; re-checking after granting clears it
        // (recovery). SEAM: the Overlay (sibling phase) will surface this same fix-it via
        // the coordinator's `accessibilityFixIt` API — nothing overlay-specific here.
        if let fixIt = coordinator.accessibilityFixIt {
            Text(fixIt.hint)
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Open \(fixIt.permission.displayName) Settings…") {
                coordinator.openFixIt(fixIt)
            }
            Button("Re-check \(fixIt.permission.displayName)") {
                coordinator.recheckAccessibility()
            }
            Divider()
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

        // PHASE 4 (TEMPORARY debug triggers): force the Overlay through each state to
        // verify its visuals + the non-activating (no focus-steal) panel now, before a
        // driver exists. Phase 6's voice loop / Phase 10's onboarding replace these
        // (mirrors the Phase 3 audio-cue debug toggle above). See plans/P1 Phase 4.
        Menu("Overlay state (debug)") {
            ForEach(OverlayState.allCases, id: \.self) { state in
                Button(state.displayName) { coordinator.overlay.debugForce(state) }
            }
        }

        Divider()

        Button("Quit Aide") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
