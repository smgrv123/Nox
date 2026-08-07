import SwiftUI

/// Hotkey setup (User Story 23's prerequisite). Reuses Phase 9's `HotkeysPane`
/// wholesale — the same chord recorder + `HotkeyChordValidation` +
/// `AppCoordinator.rebindHotkey` — rather than duplicating a second capture UI.
/// Sensible defaults (⌥Space command mode, ⌃Space dictation mode) are already
/// bound, so the common path is simply reading this screen and continuing.
struct OnboardingHotkeysStep: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hotkey Setup")
                .font(.title.bold())

            Text(
                "Both hotkeys are already set to sensible defaults, both push-to-talk (hold to talk, "
                    + "release to send). Want something else? Record a new chord below."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HotkeysPane(coordinator: coordinator)

            Spacer()

            HStack {
                Spacer()
                Button("Continue") { coordinator.onboardingAdvance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
