import Foundation
import Onboarding
import Persistence
import SwiftUI

/// Step 2 — RAM detection with a proposed model Tier the user can confirm or
/// override (User Story 17). The actual model download is **P2** scope, which also
/// owns `settings.model_tier` (see `OnboardingTier`'s doc comment) — P1 has nowhere
/// to persist the confirmed choice yet, so this screen logs it on "Continue" (below)
/// rather than silently dropping an override, and P2's persistence lands on top of
/// that once the model subsystem exists.
struct OnboardingTierStep: View {
    @ObservedObject var coordinator: AppCoordinator

    /// Physical RAM, read once at step init (an effectful `ProcessInfo` query) and
    /// reused everywhere below instead of re-querying on each view update.
    private let detectedRAMBytes: UInt64

    /// The tier `OnboardingTier.propose` recommends for `detectedRAMBytes`, derived
    /// once alongside it and reused as both the picker's default and the
    /// recommendation copy.
    private let recommendedTier: OnboardingTier

    @State private var selectedTier: OnboardingTier

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        self.detectedRAMBytes = ramBytes
        let proposed = OnboardingTier.propose(physicalMemoryBytes: ramBytes)
        self.recommendedTier = proposed
        self._selectedTier = State(initialValue: proposed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Your Model Tier")
                .font(.title.bold())

            Text("Aide detected \(detectedRAM) of RAM and recommends the \(recommendedTier.displayName) tier.")
                .foregroundStyle(.secondary)

            Picker("Tier", selection: $selectedTier) {
                ForEach(OnboardingTier.allCases, id: \.self) { tier in
                    Text(tier.displayName).tag(tier)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(
                "This is the confirmed tier the model-download step will use once it ships in P2. "
                    + "This build tries the full flow with a mocked voice loop instead, so you can see "
                    + "how onboarding works today."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button("Continue") {
                    logTierConfirmation()
                    coordinator.onboardingAdvance()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var detectedRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(detectedRAMBytes), countStyle: .memory)
    }

    /// P1 has no `Settings` field to persist the confirmed/overridden tier into yet
    /// (that's P2's `model_tier` block) — log the decision so it leaves a trace
    /// instead of vanishing the instant "Continue" is tapped.
    private func logTierConfirmation() {
        let disposition = selectedTier == recommendedTier ? "confirmed" : "overridden to"
        coordinator.appLog?.log(
            "Onboarding tier \(disposition) \(selectedTier.displayName) (detected \(detectedRAM), "
                + "recommended \(recommendedTier.displayName)).",
            level: .notice)
    }
}
