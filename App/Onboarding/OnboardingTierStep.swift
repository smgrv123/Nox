import Foundation
import ModelProvisioning
import Persistence
import SpeechToText
import SwiftUI

/// Step 2 — RAM detection with a proposed model Tier the user can confirm or override,
/// then the real provisioning of that Tier's Whisper *and* Qwen models (P2a Phase 5 /
/// P2b Phase 5; User Stories 10-15, 17, 18, 19): tapping Continue persists the confirmed
/// Tier and kicks off `AppCoordinator.confirmModelTier(_:)`, which downloads Whisper
/// first (skipping instantly if already verified), then chains straight into the Qwen
/// download the moment Whisper verifies — one honest progress bar in flight at a time,
/// labelled "Step 1 of 2" / "Step 2 of 2" so the user is never confused about which
/// model is downloading or how much is left.
///
/// This view renders whichever phase is currently active —
/// `coordinator.llmModelProvisioningState` takes priority once non-nil (Whisper already
/// verified), else `coordinator.sttModelProvisioningState`, else the tier picker — and
/// the coordinator auto-advances onboarding once BOTH models are `.ready` and the real
/// Sidecar has started with the provisioned Qwen model.
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

            if let llmState = coordinator.llmModelProvisioningState {
                provisioningView(for: llmState, phase: .llm)
            } else if let sttState = coordinator.sttModelProvisioningState {
                provisioningView(for: sttState, phase: .stt)
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

            Text(
                "Aide downloads the speech and language models for this tier once, verifies them, "
                    + "and keeps them on disk for next time."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Continue") {
                    logTierConfirmation()
                    coordinator.confirmModelTier(selectedTier)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Provisioning in flight / done / failed

    /// Which of the two sequential downloads a `ModelProvisioner.State` belongs to —
    /// drives the "Step 1 of 2"/"Step 2 of 2" heading and per-phase Retry targeting.
    private enum ModelPhase {
        case stt
        case llm

        var stepHeading: String {
            switch self {
            case .stt: return "Step 1 of 2 — Speech Model"
            case .llm: return "Step 2 of 2 — Language Model"
            }
        }

        var modelName: String {
            switch self {
            case .stt: return "speech model"
            case .llm: return "language model"
            }
        }
    }

    @ViewBuilder
    private func provisioningView(for state: ModelProvisioner.State, phase: ModelPhase) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(phase.stepHeading)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            phaseBody(for: state, phase: phase)
        }
    }

    @ViewBuilder
    private func phaseBody(for state: ModelProvisioner.State, phase: ModelPhase) -> some View {
        switch state {
        case .checking:
            statusRow("Checking for an already-downloaded \(phase.modelName)…")

        case .downloading(let bytesWritten, let totalBytes):
            VStack(alignment: .leading, spacing: 8) {
                statusRow("Downloading the \(selectedTier.displayName) \(phase.modelName)…")
                ProgressView(value: Double(bytesWritten), total: Double(max(totalBytes, 1)))
                Text("\(formattedBytes(bytesWritten)) of \(formattedBytes(totalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .verifying:
            statusRow("Verifying the download…")

        case .ready:
            // Transient — the coordinator immediately starts the next phase (stt -> llm)
            // or auto-advances onboarding (llm -> done), so this rarely renders for more
            // than a frame.
            statusRow("\(phase.modelName.capitalized) ready.")

        case .failed(let failure):
            VStack(alignment: .leading, spacing: 12) {
                Label(message(for: failure, phase: phase), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                HStack {
                    Button("Retry") { retry(phase: phase) }
                    Spacer()
                    Button("Continue anyway") {
                        coordinator.onboardingAdvance()
                    }
                }
            }
        }
    }

    private func retry(phase: ModelPhase) {
        switch phase {
        case .stt: coordinator.retrySttModelProvisioning()
        case .llm: coordinator.retryLlmModelProvisioning()
        }
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
    }

    /// A human-readable, actionable message for every non-ready outcome (User Story 19 —
    /// a model that isn't ready is always a clear state, never a crash or silent failure).
    private func message(for failure: ModelProvisioner.Failure, phase: ModelPhase) -> String {
        switch failure {
        case .downloadFailed:
            return "Couldn't download the \(phase.modelName). Check your internet connection and try again."
        case .verificationFailed:
            return "The downloaded \(phase.modelName) didn't match its checksum and may be corrupted. Try again."
        case .notReady:
            return "The \(phase.modelName) isn't ready yet."
        }
    }

    private var detectedRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(detectedRAMBytes), countStyle: .memory)
    }

    private func formattedBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Leaves a trace of the confirm/override decision in `app.log`, same as before
    /// P2b Phase 5 (the one confirmed Tier now drives both the Whisper and Qwen downloads).
    private func logTierConfirmation() {
        let disposition = selectedTier == recommendedTier ? "confirmed" : "overridden to"
        coordinator.appLog?.log(
            "Onboarding tier \(disposition) \(selectedTier.displayName) (detected \(detectedRAM), "
                + "recommended \(recommendedTier.displayName)).",
            level: .notice)
    }
}
