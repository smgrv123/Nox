import SwiftUI

/// The one-time disclosure of Aide's two keyless utility calls (User Story 22).
/// Shown at most once ever — `OnboardingFlow` skips this step automatically when
/// `settings.privacy.networkUtilitiesDisclosed` is already `true`, and
/// acknowledging here persists that flag immediately
/// (`AppCoordinator.onboardingAcknowledgeDisclosure`).
struct OnboardingDisclosureStep: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Two Small Network Calls")
                .font(.title.bold())

            Text(
                "Everything else about Aide runs on this Mac. Two built-in skills need a tiny bit of "
                    + "public data that only exists on the internet, so they make simple, keyless calls: "
                    + "weather (Open-Meteo) and currency conversion (Frankfurter). Neither sends your voice, "
                    + "your screen, or anything personal — just the query itself (e.g. a city or a currency "
                    + "pair). This is the only implicit network traffic besides the one-time model download, "
                    + "and you won't be asked about it again."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                Button("I Understand") { coordinator.onboardingAcknowledgeDisclosure() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
