import SwiftUI

/// Placeholder Settings content (User Story 28). The Settings **framework** and its
/// full P1 panes — hotkeys, overlay/indicator options, permission fix-its — arrive
/// in later P1 phases (specs/P1 §"Settings scope"). PHASE 11 adds the one P1-owned
/// pane it needs now: the one-click "Wipe all history" entry (§16.2).
struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Settings")
                .font(.headline)
            Text("Aide's settings will live here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            // PHASE 11: one-click "Wipe all history" (User Story 34). Routes through
            // the focus-taking ConfirmationModal — the real trigger that also verifies
            // the modal infra. Clears transcripts/command-history/script-logs only.
            Button(role: .destructive) {
                coordinator.requestWipeAllHistory()
            } label: {
                Label("Wipe all history…", systemImage: "trash")
            }
            Text(
                "Clears transcripts, command history, and script logs. "
                    + "Your settings, scripts, and dictionary are kept."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(width: 420, height: 300)
        .padding()
    }
}
