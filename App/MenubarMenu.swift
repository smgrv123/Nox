import AideCore
import Permissions
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

        // US3: "a menu … with status, a Local/Cloud indicator, and an entry into
        // Settings." Mirrors the Overlay's badge (`OverlayView.localCloudBadge`) so
        // the same information reads from the menubar too, gated on the same
        // `showLocalCloudIndicator` preference. P1 always renders "LOCAL" — every
        // request is local by construction this early (P6/BYOK cloud escalation is
        // what will make this live).
        if coordinator.settings.indicators.showLocalCloudIndicator {
            Text("Local/Cloud: LOCAL")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.green)
        }

        Divider()

        // P7 fix-it (User Stories 15, 26): when the hotkey path is blocked by a missing
        // Input Monitoring grant, PermissionGate supplies the hint + exact-pane deep-link.
        // Shown only while the grant is missing; re-checking after granting clears it
        // (recovery). SEAM: the Overlay (sibling phase) will surface this same fix-it via
        // the coordinator's `inputMonitoringFixIt` API — nothing overlay-specific here.
        if let fixIt = coordinator.inputMonitoringFixIt {
            Text(fixIt.hint)
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Open \(fixIt.permission.displayName) Settings…") {
                coordinator.openFixIt(fixIt)
            }
            Button("Re-check \(fixIt.permission.displayName)") {
                coordinator.recheckInputMonitoring()
            }
            Divider()
        }

        // P5a (User Story 20): Accessibility has no in-app prompt (`canRequestInApp ==
        // false`). Live-query the shared gate so the menubar deep-links to Privacy →
        // Accessibility without a published coordinator field; Overlay stays text-only
        // (plan: do not invent Overlay buttons). Settings Permissions already deep-links.
        if let accessibilityFixIt = coordinator.permissionGate.advice(for: .accessibility) {
            Text(accessibilityFixIt.hint)
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Open \(accessibilityFixIt.permission.displayName) Settings…") {
                coordinator.openFixIt(accessibilityFixIt)
            }
            Divider()
        }

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Aide") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
