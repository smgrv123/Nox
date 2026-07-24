import SwiftUI

/// Placeholder Settings content (User Story 28). Phase 1 ships the *window* only;
/// the Settings **framework** and its P1 panes — hotkeys, overlay/indicator
/// options, permission fix-its, wipe-history — are built in later P1 phases
/// (specs/P1 §"Settings scope"). Kept intentionally empty until then.
struct SettingsView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Settings")
                .font(.headline)
            Text("Aide's settings will live here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(width: 420, height: 260)
        .padding()
    }
}
