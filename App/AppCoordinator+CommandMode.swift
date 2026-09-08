import AideCore
import BuiltinSkills
import CommandDispatcher
import CommandMode
import CommandRouter
import DangerousCommandScanner
import Dictation
import Foundation
import InferenceClient
import LLMRuntime
import Persistence
import SkillRegistry
import SpeechToText
import VoiceSession
import WhisperSTTEngine

extension AppCoordinator {

    /// Async composition root for Command Mode (plan Phase 2). Pre-renders the
    /// registry grammar and catalog, builds the mux, and injects it into
    /// `VoiceSessionCoordinator`. Dictation uses `DictationDriver` (P5a Phase 2).
    func setUpCommandMode() async {
        let engine = WhisperSTTEngine(
            modelURL: AppCoordinator.modelsDirectory.blobURL(for: resolvedSttModelDescriptor))
        let capture = AudioCapture()
        let preGate = SegmentPreGate(thresholds: .provisional)

        let inserter = await MainActor.run { TextInserterLive() }
        let dictation = DictationDriver(
            engine: engine,
            capture: capture,
            preGate: preGate,
            inserter: inserter,
            scanner: DangerousCommandScanner())
        let command = await makeCommandModeDriver(engine: engine, capture: capture, preGate: preGate)
        let mux = MuxVoiceSessionDriver(command: command, dictation: dictation)

        voiceSession = VoiceSessionCoordinator(
            driver: mux,
            emit: overlay.send,
            playCue: { [weak self] in self?.playListenCue() },
            scheduleAutoHide: { work in
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + AppCoordinator.resultDisplayDuration, execute: work)
            },
            presentText: { [weak self] transcript, result in
                self?.overlay.present(transcript: transcript, result: result?.summary)
            },
            playProcessingCue: { [weak self] in self?.playProcessingCue() },
            reportStatus: { [weak self] phase in self?.reflectVoiceSessionPhase(phase) },
            scheduleConfirmBackTimeout: { work in
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + AppCoordinator.confirmBackTimeoutDuration, execute: work)
            })
        overlay.onApprove = { [weak self] in self?.voiceSession?.approveConfirmBack() }
        overlay.onReject = { [weak self] in self?.voiceSession?.rejectConfirmBack() }
    }

    private func makeCommandModeDriver(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate
    ) async -> CommandModeDriver {
        let registryDirectory: URL
        if let storage {
            registryDirectory = storage.registryDirectory
        } else {
            registryDirectory = FileManager.default.temporaryDirectory.appending(
                path: "aide-registry-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: registryDirectory, withIntermediateDirectories: true)
        }
        let registry = FileSkillRegistry(
            registryDirectory: registryDirectory,
            builtins: BuiltinManifestCatalog.all)
        let grammar = await registry.routerGrammar()
        let catalog = await registry.routerPromptSkillCatalog()
        let router = LocalCommandRouter(
            client: InferenceClient(),
            skillCatalog: catalog,
            grammar: grammar
        )
        let installedApps = InstalledApplicationCatalogLive()
        let dispatcher = CommandDispatcher(
            registry: registry,
            scanner: DangerousCommandScanner(),
            executor: BuiltinSkillRouter(system: SystemSkillExecutorLive(catalog: installedApps)),
            thresholds: .provisional
        )
        let logURL =
            storage?.calibrationLogFile
            ?? FileManager.default.temporaryDirectory.appending(path: "aide-calibration.jsonl")
        return CommandModeDriver(
            engine: engine,
            capture: capture,
            preGate: preGate,
            router: router,
            dispatcher: dispatcher,
            registry: registry,
            logger: CalibrationLogger(fileURL: logURL),
            appCatalog: installedApps,
            resolveEndpoint: { [weak self] in
                try await Self.resolveLiveSidecarEndpoint(from: self)
            }
        )
    }

    /// llama-server binds a fresh `:0` port each launch (and after idle-unload), so the
    /// Sidecar endpoint is resolved on every route rather than captured at driver init.
    ///
    /// This runs on the command router's own cooperative thread pool, not the main
    /// actor, but `sidecarManagerInstance` is main-actor-only-by-convention state also
    /// written by the main-thread launch path (`startProductionSidecar`). The
    /// check-and-create step is hopped onto the main actor via
    /// `ensureSidecarManagerIfModelProvisioned()` (`AppCoordinator+Sidecar.swift`) so
    /// both call sites always converge on the same `SidecarManager` instance rather
    /// than each racing to construct their own; `startIfNeeded`/readiness are then
    /// awaited off the main actor as before, relying on
    /// `SidecarLifecycleController.startIfNeeded`'s existing idempotency.
    private static func resolveLiveSidecarEndpoint(
        from coordinator: AppCoordinator?
    ) async throws -> LLMEndpoint {
        guard let coordinator else {
            throw LiveSidecarRouterError.sidecarUnavailable
        }
        coordinator.noteLLMActivity()
        guard
            let (manager, model) = await MainActor.run(body: {
                coordinator.ensureSidecarManagerIfModelProvisioned()
            })
        else {
            throw LiveSidecarRouterError.sidecarUnavailable
        }
        do {
            try await manager.startIfNeeded(model: model)
        } catch {
            coordinator.appLog?.log("Failed to start the LLM Sidecar: \(error)", level: .error)
            throw LiveSidecarRouterError.sidecarUnavailable
        }
        guard let endpoint = await waitForSidecarReady(manager, appLog: coordinator.appLog, timeout: 45)
        else {
            throw LiveSidecarRouterError.sidecarUnavailable
        }
        guard endpoint.isLocal else {
            throw RoutingError.cloudEndpointRejected
        }
        return endpoint
    }
}

private enum LiveSidecarRouterError: LocalizedError {
    case sidecarUnavailable

    var errorDescription: String? {
        "The local language model isn't ready yet."
    }
}
