import AppKit
import Foundation
import ModelDownloader
import ModelProvisioning
import Onboarding
import SpeechToText

/// `AppCoordinator`'s Whisper-model provisioning (P2a Phase 5; User Stories 12, 13, 15, 16,
/// 17, 18, 19), split out of the coordinator's primary declaration mirroring
/// `AppCoordinator+Onboarding.swift`. Bridges the pure `ModelProvisioning.ModelProvisioner`
/// (skip-if-verified / download / verify / ready decision logic, unit-tested with fakes) to
/// the real effectful collaborators: `ModelDownloader` (the network) and `LiveModelVerifier`
/// (the file-hash check), plus the one AppKit affordance — revealing the models directory
/// in Finder.
extension AppCoordinator {

    /// The user-discoverable models directory (docs/05-lld.md §2.7; Phase 5), resolved once.
    /// Falls back to the same hand-built path Phase 1 used if `.applicationSupport()`
    /// somehow throws (Application Support is effectively always resolvable) — never crashes.
    static let modelsDirectory: ModelsDirectory = {
        (try? ModelsDirectory.applicationSupport())
            ?? ModelsDirectory(
                containerRoot: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appending(path: "Aide", directoryHint: .isDirectory))
    }()

    /// The confirmed-or-detected Whisper `ModelDescriptor` `voiceDriver` loads from disk
    /// (Phase 5; retires Phase 1's hardcoded `ggml-base.en.bin` path; User Story 18): the
    /// onboarding-confirmed Tier (`settings.sttModelTier`) wins when present, else the Tier
    /// detected from physical RAM — exactly `SttTierPolicy`'s override contract.
    var resolvedSttModelDescriptor: ModelDescriptor {
        let override = settings.sttModelTier.flatMap(SttTierPolicy.Tier.init(rawValue:))
        return SttTierPolicy.whisperModel(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, override: override)
    }

    /// Onboarding's tier-confirm action (User Stories 12, 18): persist the user's confirmed
    /// (possibly overridden) Tier so it survives relaunch, then provision that Tier's
    /// Whisper model — skip instantly if it's already downloaded and verified, else download
    /// → verify → ready. `OnboardingTierStep` observes `sttModelProvisioningState` for the
    /// resulting progress/failure/ready UI.
    func confirmSttTier(_ tier: SttTierPolicy.Tier) {
        updateSettings { $0.sttModelTier = tier.rawValue }
        provisionSttModel(descriptor: SttTierPolicy.whisperModel(for: tier))
    }

    /// Re-run provisioning for the currently confirmed-or-detected Tier — the tier step's
    /// "Retry" affordance after a `.failed` state (User Story 15: an actionable failure,
    /// never a dead end).
    func retrySttModelProvisioning() {
        provisionSttModel(descriptor: resolvedSttModelDescriptor)
    }

    /// Reveal the models directory in Finder (User Story 16), creating it first if it
    /// doesn't exist yet so there's always something to reveal (e.g. before any download
    /// has run). Best-effort: a failure to create the directory still attempts the reveal.
    func revealModelsFolderInFinder() {
        try? AppCoordinator.modelsDirectory.create()
        NSWorkspace.shared.activateFileViewerSelecting([AppCoordinator.modelsDirectory.revealInFinderURL])
    }

    /// Drive the pure `ModelProvisioner` against the real downloader/verifier, publishing
    /// every phase to `sttModelProvisioningState` and auto-advancing onboarding past the
    /// tier step the moment the model is `.ready` (a stalled `.failed`/`.downloading` state
    /// never auto-advances — the user drives those via Retry / "Continue anyway").
    /// Cancels any prior in-flight attempt first so Retry can never race a stale download.
    private func provisionSttModel(descriptor: ModelDescriptor) {
        sttModelProvisioningTask?.cancel()
        let provisioner = ModelProvisioner(
            downloader: ModelDownloader(),
            verifier: LiveModelVerifier(),
            modelsDirectory: AppCoordinator.modelsDirectory)

        sttModelProvisioningTask = Task { [weak self] in
            _ = await provisioner.provision(descriptor: descriptor) { state in
                Task { @MainActor in self?.handle(state) }
            }
        }
    }

    @MainActor
    private func handle(_ state: ModelProvisioner.State) {
        sttModelProvisioningState = state
        if case .ready = state, onboardingFlow?.currentStep == .tier {
            onboardingAdvance()
        }
    }
}
