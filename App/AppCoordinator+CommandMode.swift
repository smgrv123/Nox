import AideCore
import BuiltinSkills
import CommandDispatcher
import CommandMode
import CommandRouter
import Configuration
import DangerousCommandScanner
import Dictation
import Foundation
import InferenceClient
import LLMRuntime
import Persistence
import Personalization
import SkillRegistry
import SpeechToText
import VoiceSession
import WhisperSTTEngine

extension AppCoordinator {

    /// Async composition root for Command Mode (plan Phase 2). Pre-renders the
    /// registry grammar and catalog, builds the mux, and injects it into
    /// `VoiceSessionCoordinator`. Dictation uses `DictationDriver` (P5a Phase 5).
    func setUpCommandMode() async {
        let engine = WhisperSTTEngine(
            modelURL: AppCoordinator.modelsDirectory.blobURL(for: resolvedSttModelDescriptor))
        let capture = AudioCapture()
        let preGate = SegmentPreGate(thresholds: .provisional)
        let dictionary = makeDictionaryStore()
        let installedApps: any InstalledApplicationCatalog = InstalledApplicationCatalogLive()
        let makePrompt = makeBiasInitialPrompt(
            engine: engine, dictionary: dictionary, installedApps: installedApps)

        let dictation = await makeDictationDriver(
            engine: engine, capture: capture, preGate: preGate,
            makeInitialPrompt: makePrompt,
            dictionarySubstitutions: makeDictionarySubstitutions(dictionary))
        let command = await makeCommandModeDriver(
            engine: engine, capture: capture, preGate: preGate,
            dictionary: dictionary, makeInitialPrompt: makePrompt)
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

    private func makeDictationDriver(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate,
        makeInitialPrompt: @escaping @Sendable () async -> String?,
        dictionarySubstitutions: @escaping @Sendable () async -> String
    ) async -> DictationDriver {
        let inserter = await MainActor.run { TextInserterLive() }
        return DictationDriver(
            engine: engine,
            capture: capture,
            preGate: preGate,
            inserter: inserter,
            scanner: DangerousCommandScanner(),
            llm: InferenceClient(),
            // Bounded to `SidecarReadinessPolicy.launchWaitDeadline` (2s), not Command
            // Mode's 45s default: this closure runs after the readiness probe above has
            // already decided to proceed, and only re-resolves the endpoint because
            // `llama-server` binds a fresh port each launch. Without its own short bound
            // it would inherit Command Mode's full 45s cold-start wait if the sidecar
            // idle-unloaded in the gap between that probe and this call — the exact race
            // this parameterization closes. `.notice` because that race, like the probe
            // itself, resolves to dictation's designed raw-insert fallback, not a failure.
            resolveEndpoint: { [weak self] in
                try await Self.resolveLiveSidecarEndpoint(
                    from: self,
                    timeout: SidecarReadinessPolicy.launchWaitDeadline,
                    severity: .notice)
            },
            tonePreset: { [weak self] in
                self?.settings.tone.defaultPreset ?? .asIs
            },
            cleanupEnabled: { [weak self] in
                self?.settings.dictation.cleanupEnabled ?? true
            },
            sidecarReadiness: { [weak self] in
                guard let self else { return .unavailable }
                let manager = await MainActor.run { self.sidecarManagerInstance }
                guard let manager else { return .unavailable }
                let state = await manager.state
                return SidecarReadinessPolicy.readiness(for: state)
            },
            awaitSidecarReady: { [weak self] deadline in
                guard let self else { return false }
                let manager = await MainActor.run { self.sidecarManagerInstance }
                guard let manager else { return false }
                return await awaitDictationSidecarReady(manager: manager, appLog: self.appLog, deadline: deadline)
            },
            noteSidecarActivity: { [weak self] in
                await self?.noteLLMActivity()
            },
            makeInitialPrompt: makeInitialPrompt,
            dictionarySubstitutions: dictionarySubstitutions,
            appendHistory: { [weak self] entry in
                self?.recordDictationCompletion(entry.cleaned ?? entry.transcript)
                guard let storage = self?.storage else { return }
                try? HistoryLog(fileURL: storage.historyFile(for: Date())).append(entry)
            })
    }

    private func makeCommandModeDriver(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate,
        dictionary: DictionaryStore?,
        makeInitialPrompt: @escaping @Sendable () async -> String?
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
            executor: BuiltinSkillRouter(
                system: SystemSkillExecutorLive(catalog: installedApps),
                dictionary: dictionary),
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
            makeInitialPrompt: makeInitialPrompt,
            resolveEndpoint: { [weak self] in
                try await Self.resolveLiveSidecarEndpoint(from: self)
            }
        )
    }

    private func makeDictionaryStore() -> DictionaryStore? {
        guard let storage else { return nil }
        return DictionaryStore(fileURL: storage.dictionaryFile)
    }

    private func makeDictionarySubstitutions(
        _ dictionary: DictionaryStore?
    ) -> @Sendable () async -> String {
        {
            guard let dictionary else { return "" }
            let entries = await dictionary.promotedEntries()
            return SubstitutionListBuilder.build(promotedEntries: entries)
        }
    }

    /// Shared Whisper `initialPrompt` for Command Mode and Dictation: ranked dictionary
    /// terms first, leftover budget for installed-app names. Tokenizer load failure
    /// falls back to the app-name prompt only — never a char-count fake.
    private func makeBiasInitialPrompt(
        engine: WhisperSTTEngine,
        dictionary: DictionaryStore?,
        installedApps: any InstalledApplicationCatalog
    ) -> @Sendable () async -> String? {
        { [weak self] in
            let extraPhrases = await Self.appNameBiasPhrases(installedApps)
            let appNamesOnly = extraPhrases.isEmpty ? nil : extraPhrases.joined(separator: ", ")
            guard let dictionary else { return appNamesOnly }
            let entries = await dictionary.promotedEntries()
            do {
                return try await engine.withTokenCounter { counter in
                    BiasPromptBuilder().build(
                        promotedEntries: entries,
                        extraPhrases: extraPhrases,
                        counter: counter)
                }
            } catch {
                self?.appLog?.log(
                    "Bias prompt: tokenizer unavailable (\(error)); using app-name prompt.",
                    level: .notice)
                return appNamesOnly
            }
        }
    }

    private static func appNameBiasPhrases(
        _ catalog: any InstalledApplicationCatalog
    ) async -> [String] {
        guard let joined = await CommandModeDriver.appNameBiasPrompt(catalog) else { return [] }
        return joined.components(separatedBy: ", ")
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
    ///
    /// Dictation must **not** take Command Mode's 45s cold-start wait: its `resolveEndpoint`
    /// closure (above) passes `timeout: SidecarReadinessPolicy.launchWaitDeadline` (2s) so
    /// this function itself enforces the bound, structurally closing the idle-unload race
    /// between the readiness probe and this call (rather than relying on the probe alone).
    /// Command Mode's own call site below is unparameterized, so its `timeout: TimeInterval
    /// = 45` default keeps its behavior — including a genuine timeout logging at `.error`
    /// via the shared `LiveSidecarRouterError.sidecarUnavailable` throw — byte-for-byte
    /// identical to before this function grew a `timeout`/`severity` parameter.
    private static func resolveLiveSidecarEndpoint(
        from coordinator: AppCoordinator?,
        timeout: TimeInterval = 45,
        severity: AppLog.Level = .error
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
        guard
            let endpoint = await waitForSidecarReady(
                manager,
                appLog: coordinator.appLog,
                timeout: timeout,
                timeoutMessage:
                    "Sidecar endpoint resolution: timed out after \(timeout)s waiting for .ready.",
                failedMessage: { reason in
                    "Sidecar endpoint resolution: reached .failed(\(reason)) while waiting for .ready."
                },
                severity: severity)
        else {
            throw LiveSidecarRouterError.sidecarUnavailable
        }
        guard endpoint.isLocal else {
            throw RoutingError.cloudEndpointRejected
        }
        return endpoint
    }

}

/// Dictation's `awaitSidecarReady` closure body (`makeDictationDriver`, above), split out
/// to a free function purely to keep that initializer call under SwiftLint's
/// function-body-length ceiling — no behavior change. `SidecarReadinessPolicy`'s bounded
/// wait on a *launching* sidecar is the designed, expected path (falls back to a raw
/// insert on timeout), not a failure, so — unlike the Phase-3 debug hook's default
/// copy/severity on `waitForSidecarReady` — this logs honestly at `.notice`.
private func awaitDictationSidecarReady(
    manager: SidecarManager, appLog: AppLog?, deadline: TimeInterval
) async -> Bool {
    let endpoint = await waitForSidecarReady(
        manager,
        appLog: appLog,
        timeout: deadline,
        timeoutMessage:
            "Dictation: sidecar still launching after \(deadline)s — inserting the raw transcript.",
        failedMessage: { reason in
            "Dictation: sidecar reached .failed(\(reason)) while launching — inserting the raw transcript."
        },
        severity: .notice)
    return endpoint != nil
}

private enum LiveSidecarRouterError: LocalizedError {
    case sidecarUnavailable

    var errorDescription: String? {
        "The local language model isn't ready yet."
    }
}
