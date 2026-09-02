import AideCore
import BuiltinSkills
import CommandDispatcher
import CommandMode
import CommandRouter
import DangerousCommandScanner
import Foundation
import InferenceClient
import LLMRuntime
import Persistence
import STTVoiceSession
import SkillRegistry
import SpeechToText
import VoiceSession
import WhisperSTTEngine

extension AppCoordinator {

    /// Async composition root for Command Mode (plan Phase 2). Pre-renders the
    /// registry grammar and catalog, builds the mux, and injects it into
    /// `VoiceSessionCoordinator`. Dictation still uses `STTVoiceSessionDriver`.
    func setUpCommandMode() async {
        let engine = WhisperSTTEngine(
            modelURL: AppCoordinator.modelsDirectory.blobURL(for: resolvedSttModelDescriptor))
        let capture = AudioCapture()
        let preGate = SegmentPreGate(thresholds: .provisional)

        let dictation = STTVoiceSessionDriver(engine: engine, capture: capture, preGate: preGate)
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
            reportStatus: { [weak self] phase in self?.reflectVoiceSessionPhase(phase) })
    }

    private func makeCommandModeDriver(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate
    ) async -> CommandModeDriver {
        let registry = InMemorySkillRegistry(manifests: BuiltinManifestCatalog.all)
        let grammar = await registry.routerGrammar()
        let catalog = await registry.routerPromptSkillCatalog()
        let router = LocalCommandRouter(
            client: InferenceClient(),
            skillCatalog: catalog,
            grammar: grammar
        )
        let dispatcher = CommandDispatcher(
            registry: registry,
            scanner: DangerousCommandScanner(),
            executor: BuiltinSkillRouter(system: StubSystemSkillExecutor()),
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
            resolveEndpoint: { [weak self] in
                try await Self.resolveLiveSidecarEndpoint(from: self)
            }
        )
    }

    /// llama-server binds a fresh `:0` port each launch (and after idle-unload), so the
    /// Sidecar endpoint is resolved on every route rather than captured at driver init.
    private static func resolveLiveSidecarEndpoint(
        from coordinator: AppCoordinator?
    ) async throws -> LLMEndpoint {
        coordinator?.noteLLMActivity()
        guard let manager = coordinator?.sidecarManagerInstance else {
            throw LiveSidecarRouterError.sidecarUnavailable
        }
        guard let endpoint = await waitForSidecarReady(manager, appLog: coordinator?.appLog, timeout: 45)
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
