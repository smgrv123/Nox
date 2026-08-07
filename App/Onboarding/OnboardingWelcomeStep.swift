import SwiftUI

/// Step 1 — welcome + the one-paragraph privacy promise (User Story 16).
struct OnboardingWelcomeStep: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Aide")
                .font(.largeTitle.bold())

            Text(
                "Aide is local-first: your voice, your screen, and everything it understands about you "
                    + "stays on this Mac. Speech recognition and the assistant itself run entirely on-device — "
                    + "nothing you say or see is sent anywhere unless you explicitly turn on a cloud option "
                    + "yourself. The only network traffic Aide ever makes on its own is a one-time model "
                    + "download and two small, disclosed lookups (weather and currency) — both covered later "
                    + "in this walkthrough."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                Button("Get Started") { coordinator.onboardingAdvance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
