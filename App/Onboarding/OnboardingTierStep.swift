import Foundation
import ModelProvisioning
import Persistence
import SpeechToText
import SwiftUI

/// Step 2 — RAM detection with a proposed model Tier the user can confirm or override,
/// then the real Phase 5 provisioning of that Tier's Whisper model (User Stories 12, 13,
/// 15, 17, 18, 19): tapping Continue persists the confirmed Tier and kicks off
/// `AppCoordinator.confirmSttTier(_:)`, which skips instantly if the model is already
/// downloaded and verified, else downloads → verifies. This view renders whichever phase
/// `coordinator.sttModelProvisioningState` reports — honest progress, an actionable
/// failure (Retry / Continue anyway), or nothing yet (still the picker) — and the
/// coordinator auto-advances onboarding the moment the model is `.ready`.
struct OnboardingTierStep: View {
    @ObservedObject var coordinator: AppCoordinator

    /// Physical RAM, read once at step init (an effectful `ProcessInfo` query) and
    /// reused everywhere below instead of re-querying on each view update.
    private let detectedRAMBytes: UInt64

    /// The tier `SttTierPolicy.tier` recommends for `detectedRAMBytes`, derived once
    /// alongside it and reused as both the picker's default and the recommendation copy.
    private let recommendedTier: SttTierPolicy.Tier

    @State private var selectedTier: SttTierPolicy.Tier

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        self.detectedRAMBytes = ramBytes
        let proposed = SttTierPolicy.tier(physicalMemoryBytes: ramBytes)
        self.recommendedTier = proposed
        self._selectedTier = State(initialValue: proposed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Your Model Tier")
                .font(.title.bold())

            Text("Aide detected \(detectedRAM) of RAM and recommends the \(recommendedTier.displayName) tier.")
                .foregroundStyle(.secondary)

            if let state = coordinator.sttModelProvisioningState {
                provisioningView(for: state)
            } else {
                pickerView
            }

            Spacer()
        }
    }

    // MARK: - Before provisioning starts: pick (or accept) a Tier

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Tier", selection: $selectedTier) {
                ForEach(SttTierPolicy.Tier.allCases, id: \.self) { tier in
                    Text(tier.displayName).tag(tier)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text("Aide downloads the speech model for this tier once, verifies it, and keeps it on disk for next time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Continue") {
                    logTierConfirmation()
                    coordinator.confirmSttTier(selectedTier)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Provisioning in flight / done / failed

    @ViewBuilder
    private func provisioningView(for state: ModelProvisioner.State) -> some View {
        switch state {
        case .checking:
            statusRow("Checking for an already-downloaded model…")

        case .downloading(let bytesWritten, let totalBytes):
            VStack(alignment: .leading, spacing: 8) {
                statusRow("Downloading the \(selectedTier.displayName) speech model…")
                ProgressView(value: Double(bytesWritten), total: Double(max(totalBytes, 1)))
                Text("\(formattedBytes(bytesWritten)) of \(formattedBytes(totalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .verifying:
            statusRow("Verifying the download…")

        case .ready:
            // Transient — `AppCoordinator` auto-advances past this step the instant it
            // observes `.ready`, so this rarely renders for more than a frame.
            statusRow("Speech model ready.")

        case .failed(let failure):
            VStack(alignment: .leading, spacing: 12) {
                Label(message(for: failure), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                HStack {
                    Button("Retry") {
                        coordinator.retrySttModelProvisioning()
                    }
                    Spacer()
                    Button("Continue anyway") {
                        coordinator.onboardingAdvance()
                    }
                }
            }
        }
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
    }

    /// A human-readable, actionable message for every non-ready outcome (User Story 19 —
    /// "speech model not ready" is always a clear state, never a crash or silent failure).
    private func message(for failure: ModelProvisioner.Failure) -> String {
        switch failure {
        case .downloadFailed:
            return "Couldn't download the speech model. Check your internet connection and try again."
        case .verificationFailed:
            return "The downloaded speech model didn't match its checksum and may be corrupted. Try again."
        case .notReady:
            return "The speech model isn't ready yet."
        }
    }

    private var detectedRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(detectedRAMBytes), countStyle: .memory)
    }

    private func formattedBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Leaves a trace of the confirm/override decision in `app.log`, same as before Phase 5
    /// (now confirming a Tier that actually drives a real download, not just a placeholder).
    private func logTierConfirmation() {
        let disposition = selectedTier == recommendedTier ? "confirmed" : "overridden to"
        coordinator.appLog?.log(
            "Onboarding tier \(disposition) \(selectedTier.displayName) (detected \(detectedRAM), "
                + "recommended \(recommendedTier.displayName)).",
            level: .notice)
    }
}
