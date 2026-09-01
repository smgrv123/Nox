import AppKit
import Foundation
import LLMRuntime
import ModelDownloader
import ModelProvisioning
import Onboarding
import SpeechToText

/// `AppCoordinator`'s model provisioning (P2a Phase 5 for Whisper, P2b Phase 5 for Qwen;
/// User Stories 10-19), split out of the coordinator's primary declaration mirroring
/// `AppCoordinator+Onboarding.swift`. Bridges the pure `ModelProvisioning.ModelProvisioner`
/// (skip-if-verified / download / verify / ready decision logic, unit-tested with fakes) to
/// the real effectful collaborators: `ModelDownloader` (the network) and `LiveModelVerifier`
/// (the file-hash check), plus the one AppKit affordance — revealing the models directory
/// in Finder.
///
/// **P2b Phase 5:** onboarding's one tier-confirm step now provisions BOTH models off the
/// single confirmed Tier — Whisper first (unchanged from P2a), then, the moment it
/// verifies, the Tier-appropriate Qwen GGUF (`LlmTierPolicy`). Sequential, not concurrent:
/// exactly one honest, clearly-labelled progress bar on screen at a time (`OnboardingTierStep`
/// shows "Step 1 of 2"/"Step 2 of 2"), and a smaller peak disk/network footprint than
/// streaming two multi-GB downloads at once. The instant Qwen verifies,
/// `AppCoordinator+Sidecar.swift`'s `startProductionSidecar(model:)` brings the real Sidecar
/// up with it — retiring Phase 1-3's manually-placed dev GGUF as the *production* path (the
/// opt-in `AIDE_RUN_SIDECAR_CHECK` dev hook is untouched, for manual verification without a
/// real download).
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

    /// The onboarding-confirmed Tier parsed from the persisted raw value, or `nil` when the
    /// user hasn't confirmed yet (letting policies fall back to RAM detection).
    private var resolvedTierOverride: SttTierPolicy.Tier? {
        settings.modelTier.flatMap(SttTierPolicy.Tier.init(rawValue:))
    }

    /// The confirmed-or-detected Whisper `ModelDescriptor` `voiceDriver` loads from disk
    /// (Phase 5; retires Phase 1's hardcoded `ggml-base.en.bin` path; User Story 18): the
    /// onboarding-confirmed Tier (`settings.modelTier`) wins when present, else the Tier
    /// detected from physical RAM — exactly `SttTierPolicy`'s override contract.
    var resolvedSttModelDescriptor: ModelDescriptor {
        SttTierPolicy.whisperModel(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, override: resolvedTierOverride)
    }

    /// The confirmed-or-detected Qwen `ModelDescriptor` the Sidecar loads (P2b Phase 5):
    /// the exact same Tier and override contract as `resolvedSttModelDescriptor` — HLD §4.3
    /// ties one Whisper model *and* one Qwen model to the same RAM row, so both read the
    /// same persisted `settings.modelTier`; there is no separate `llmModelTier` setting.
    var resolvedLlmModelDescriptor: ModelDescriptor {
        LlmTierPolicy.qwenModel(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, override: resolvedTierOverride)
    }

    /// Onboarding's tier-confirm action (User Stories 10-15, 18): persist the user's
    /// confirmed (possibly overridden) Tier so it survives relaunch, then provision that
    /// Tier's Whisper model. `OnboardingTierStep` observes `sttModelProvisioningState`;
    /// once Whisper verifies, `handleSttProvisioning(_:)` below chains straight into the
    /// Qwen download, so the user only taps Continue once for both models.
    func confirmModelTier(_ tier: SttTierPolicy.Tier) {
        updateSettings { $0.modelTier = tier.rawValue }
        provisionSttModel(descriptor: SttTierPolicy.whisperModel(for: tier))
    }

    /// Re-run provisioning for the currently confirmed-or-detected Whisper Tier — the
    /// tier step's "Retry" affordance after a `.failed` state (User Story 15: an
    /// actionable failure, never a dead end).
    func retrySttModelProvisioning() {
        provisionSttModel(descriptor: resolvedSttModelDescriptor)
    }

    /// Re-run provisioning for the currently confirmed-or-detected Qwen Tier — the LLM
    /// phase's own "Retry" affordance, independent of Whisper's (same contract).
    func retryLlmModelProvisioning() {
        provisionLlmModel(descriptor: resolvedLlmModelDescriptor)
    }

    /// Reveal the models directory in Finder (User Story 16), creating it first if it
    /// doesn't exist yet so there's always something to reveal (e.g. before any download
    /// has run). Best-effort: a failure to create the directory still attempts the reveal.
    func revealModelsFolderInFinder() {
        try? AppCoordinator.modelsDirectory.create()
        NSWorkspace.shared.activateFileViewerSelecting([AppCoordinator.modelsDirectory.revealInFinderURL])
    }

    // MARK: - Provisioning core

    /// Shared provisioning driver: cancel any prior in-flight attempt, build a fresh
    /// `ModelProvisioner`, and launch a new `Task` that publishes every phase through
    /// `handler`. Both `provisionSttModel` and `provisionLlmModel` delegate here.
    private func provisionModel(
        descriptor: ModelDescriptor,
        cancelExisting: () -> Void,
        storeTask: @escaping (Task<Void, Never>) -> Void,
        handler: @MainActor @Sendable @escaping (ModelProvisioner.State) -> Void
    ) {
        cancelExisting()
        let provisioner = ModelProvisioner(
            downloader: ModelDownloader(),
            verifier: LiveModelVerifier(),
            modelsDirectory: AppCoordinator.modelsDirectory)

        let task = Task { [weak self] in
            guard self != nil else { return }
            _ = await provisioner.provision(descriptor: descriptor) { state in
                Task { @MainActor in handler(state) }
            }
        }
        storeTask(task)
    }

    // MARK: - Whisper (STT)

    /// Drive the pure `ModelProvisioner` for the Whisper descriptor, publishing every phase
    /// to `sttModelProvisioningState`. Cancels any prior in-flight attempt first so Retry
    /// can never race a stale download.
    private func provisionSttModel(descriptor: ModelDescriptor) {
        provisionModel(
            descriptor: descriptor,
            cancelExisting: { [self] in sttModelProvisioningTask?.cancel() },
            storeTask: { [self] in sttModelProvisioningTask = $0 },
            handler: { [weak self] state in self?.handleSttProvisioning(state) }
        )
    }

    /// Once Whisper reaches `.ready` **during onboarding's tier step**, chain straight into
    /// Qwen (sequential — one progress bar in flight at a time, never two at once). The
    /// `.tier` guard ensures a standalone STT retry outside onboarding never accidentally
    /// kicks off a Qwen download. A `.failed`/`.checking`/`.downloading`/`.verifying` state
    /// never auto-starts Qwen or advances onboarding — the user drives those outcomes via
    /// Retry / "Continue anyway" (`OnboardingTierStep`).
    @MainActor
    private func handleSttProvisioning(_ state: ModelProvisioner.State) {
        sttModelProvisioningState = state
        if case .ready = state, onboardingFlow?.currentStep == .tier {
            provisionLlmModel(descriptor: resolvedLlmModelDescriptor)
        }
    }

    // MARK: - Qwen (LLM)

    /// Drive the pure `ModelProvisioner` for the Qwen descriptor, publishing every phase to
    /// `llmModelProvisioningState`. Cancels any prior in-flight attempt first — same
    /// contract as `provisionSttModel`.
    private func provisionLlmModel(descriptor: ModelDescriptor) {
        provisionModel(
            descriptor: descriptor,
            cancelExisting: { [self] in llmModelProvisioningTask?.cancel() },
            storeTask: { [self] in llmModelProvisioningTask = $0 },
            handler: { [weak self] state in self?.handleLlmProvisioning(state, descriptor: descriptor) }
        )
    }

    /// Once Qwen verifies, bring the real Sidecar up with it (User Stories 10-15;
    /// `AppCoordinator+Sidecar.swift`'s `startProductionSidecar(model:)` — this is what
    /// retires the dev-only manual placement as the *production* path) and auto-advance
    /// onboarding past the tier step, mirroring `handleSttProvisioning`'s auto-advance
    /// contract now that both models are `.ready`.
    @MainActor
    private func handleLlmProvisioning(_ state: ModelProvisioner.State, descriptor: ModelDescriptor) {
        llmModelProvisioningState = state
        guard case .ready = state else { return }
        startProductionSidecar(model: descriptor)
        if onboardingFlow?.currentStep == .tier {
            onboardingAdvance()
        }
    }
}
