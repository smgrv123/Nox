import Permissions
import SwiftUI

/// Graceful-degradation summary (User Story 25's onboarding-side recap). Lists
/// every `Feature`, split into what's available vs. disabled given the permission
/// grants made during this walkthrough — sourced from `coordinator.permissionGate`,
/// the one `PermissionGate` `AppCoordinator` owns (docs/05-lld.md §8), the same
/// degradation map the Permissions Settings pane and the menubar fix-it already use.
/// Finishing here marks onboarding complete.
struct OnboardingSummaryStep: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You're All Set")
                .font(.title.bold())

            Text("Here's what's available right now. Anything disabled can be granted later in Settings.")
                .foregroundStyle(.secondary)

            List(Feature.allCases, id: \.self) { feature in
                HStack {
                    Text(feature.displayName)
                    Spacer()
                    if coordinator.permissionGate.isEnabled(feature) {
                        Label("Available", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Disabled", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Spacer()
                Button("Finish") { coordinator.onboardingAdvance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
