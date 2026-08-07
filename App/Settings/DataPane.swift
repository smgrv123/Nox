import SwiftUI

/// The Data pane (Phase 8): home for P1's data-management actions. Currently
/// just the one-click "Wipe all history" entry (Phase 11; User Story 34),
/// relocated here from the pre-Phase-8 placeholder `SettingsView` now that
/// panes have a real, registrable home. Routes through
/// `AppCoordinator.requestWipeAllHistory()`, which itself goes through the
/// focus-taking `ConfirmationModal` before anything is deleted.
struct DataPane: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "trash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Data")
                .font(.headline)

            Divider()

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

            Spacer()
        }
        .padding()
    }
}
