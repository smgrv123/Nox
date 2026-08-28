import SwiftUI

/// The Data pane (Phase 8): home for P1's data-management actions — "Wipe all history"
/// (Phase 11; User Story 34) and, since Phase 5 (P2a), revealing the models directory in
/// Finder (User Story 16) — since P2b Phase 5, that's both the speech model *and* the
/// language model, which share the same on-disk directory (`AppCoordinator.modelsDirectory`).
/// Both route through `AppCoordinator`: the wipe through the focus-taking
/// `ConfirmationModal` before anything is deleted; the reveal through
/// `AppCoordinator.revealModelsFolderInFinder()`, a direct `NSWorkspace` call (nothing
/// destructive to confirm).
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

            Divider()

            Button {
                coordinator.revealModelsFolderInFinder()
            } label: {
                Label("Reveal models in Finder…", systemImage: "folder")
            }
            Text("Shows where Aide stores the downloaded speech-recognition and language models on disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }
}
