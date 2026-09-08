import AppKit
import Foundation
import InferenceClient
import LLMRuntime
import ModelProvisioning
import Persistence

/// Plan Phase 2/3 (plans/P2b-llm-runtime.md): an opt-in, env-var-gated launch hook that
/// exercises the real `SidecarManager` end-to-end — spawn, reach `.ready`, and then
/// stay up so a person can `kill`/`pkill` the child `llama-server` process from a
/// terminal and watch it auto-restart within the backoff window (the phase's
/// "integration-verified: kill the process, watch it restart" acceptance criterion).
/// Every state transition is timestamped to `logs/app.log` via `onStateChange`, so the
/// restart timing is directly observable without polling.
///
/// Phase 3 adds a minimal manual debug affordance on top: once `.ready`, it fires one
/// real non-streamed `chat()` call and one real streamed `chat()` call through the real
/// `InferenceClient`, logging each rendered completion to `logs/app.log` — proof the
/// full stack (`SidecarManager` -> `InferenceClient` -> real Qwen completion) works
/// end-to-end for a person to read, not just a test (plan Phase 3's "manual debug hook"
/// acceptance criterion). Not a real feature — P4/P5/P6 don't exist yet to be the true
/// consumer of `LLMClient`; this is the same "point something real at it and watch"
/// spirit as P2a's live Overlay demo.
///
/// Absorbs Phase 1's `runSidecarSpikeIfRequested()` hook (retired along with
/// `LlamaServerSidecarSpike.swift`/`AppCoordinator+SidecarSpike.swift`) — same opt-in
/// env-var pattern, mirroring P2a's `AIDE_RUN_STT_INTEGRATION` precedent, now driving
/// the real lifecycle state machine instead of a bare one-shot spawn. Renamed
/// `AIDE_RUN_SIDECAR_SPIKE` -> `AIDE_RUN_SIDECAR_CHECK` since what it exercises is no
/// longer a throwaway spike (docs/native-deps.md is updated to match).
///
/// **P2b Phase 5** adds `startProductionSidecar(model:)` below — the *production* path
/// that brings the Sidecar up with a real onboarding-provisioned Qwen model, no env-var
/// or manual placement required. It shares this same handle rather than keeping a
/// second one, so `applicationShouldTerminate(_:)` always tears down whichever of the
/// two actually ran a given launch (in practice mutually exclusive: the dev hook only
/// fires when a developer explicitly sets `AIDE_RUN_SIDECAR_CHECK=1`).
///
/// **P2b Phase 6** adds idle-unload wiring (LLD §5.4): the Sidecar's
/// `SidecarLifecycleController` evaluates `IdleUnloadPolicy` on each ready-poll tick
/// and stops itself once the idle threshold is exceeded. `noteLLMActivity()` resets
/// the idle timer and, if the Sidecar was idle-unloaded, restarts it — the normal
/// `.launching` → `.ready` flow produces a brief visible loading state. Both tiers now
/// idle-unload: 16GB after `IdleUnloadPolicy.tier16IdleThreshold` (3min, since the
/// resident Qwen3-8B costs ~4.7GB of RAM held indefinitely otherwise), 8GB after
/// `IdleUnloadPolicy.defaultIdleThreshold` (5min, unchanged) — the tier-appropriate
/// threshold is resolved and passed explicitly in `ensureSidecarManager(model:)` below.
///
extension AppCoordinator {

    /// Called once from `applicationDidFinishLaunching()`. No-ops unless
    /// `AIDE_RUN_SIDECAR_CHECK=1` is set, so ordinary launches (and `just app`/`just
    /// check`) are completely unaffected.
    func runSidecarCheckIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["AIDE_RUN_SIDECAR_CHECK"] == "1" else { return }
        guard let config = resolveSidecarCheckConfig(env: env, storage: storage, appLog: appLog) else { return }

        let appLog = self.appLog
        let manager = SidecarManager(
            binaryDirectory: config.binaryDirectory,
            logFileURL: config.logFileURL,
            modelsDirectory: config.modelsDirectory,
            onStateChange: { state in
                appLog?.log("Sidecar check: state -> \(state)", level: .notice)
            })
        sidecarManagerInstance = manager

        Task {
            do {
                try await manager.startIfNeeded(model: config.descriptor)
                appLog?.log(
                    "Sidecar check: startIfNeeded returned — watch logs/app.log for state "
                        + "transitions and logs/sidecar.log for the llama-server process log.")
            } catch {
                appLog?.log("Sidecar check failed to start: \(error)", level: .error)
                return
            }

            guard let endpoint = await waitForSidecarReady(manager, appLog: appLog) else { return }
            await runDebugChat(endpoint: endpoint, stream: false, appLog: appLog)
            await runDebugChat(endpoint: endpoint, stream: true, appLog: appLog)
        }
    }

    /// Bring the real Sidecar up with a freshly provisioned Qwen model (P2b Phase 5;
    /// User Stories 10-15) — called by `AppCoordinator+ModelProvisioning.swift` the
    /// instant onboarding's Qwen download verifies. This is the *production* path: the
    /// real bundled `llama-server` (`Bundle.main.resourceURL`), the real
    /// `logs/sidecar.log`, and the real `AppCoordinator.modelsDirectory` — no env-var,
    /// no manually-placed dev GGUF. `startIfNeeded` itself is idempotent (a no-op once
    /// already launching/ready), so calling this again on a Retry-after-failure is safe.
    ///
    /// **Phase 6 (LLD §5.4):** the `Tier` is passed to `SidecarManager` at construction
    /// time. `SidecarLifecycleController` evaluates `IdleUnloadPolicy` on each
    /// ready-poll tick and stops the process when the tier-appropriate idle threshold
    /// is exceeded — 16GB at 3 minutes, 8GB at 5 minutes (see
    /// `ensureSidecarManager(model:)`'s doc comment). The idle timer resets via
    /// `recordActivity()` (called by `noteLLMActivity()` and `startIfNeeded`).
    /// Subsequent launches skip onboarding, so Qwen provisioning never runs and the
    /// Sidecar would stay down — Command Mode then cannot route. If the provisioned
    /// blob is on disk, bring llama-server up (integrity was checked at download).
    func startSidecarIfModelReady() {
        let descriptor = resolvedLlmModelDescriptor
        let blobURL = AppCoordinator.modelsDirectory.blobURL(for: descriptor)
        guard FileManager.default.fileExists(atPath: blobURL.path) else { return }
        startProductionSidecar(model: descriptor)
    }

    func startProductionSidecar(model: ModelDescriptor) {
        // `startProductionSidecar` itself is nonisolated (unchanged signature — see
        // `ensureSidecarManager(model:)`'s doc comment for why) so it can keep being
        // called synchronously from both of its guaranteed-main-thread callers:
        // `applicationDidFinishLaunching()` (an `NSApplicationDelegate` hook, always
        // main-thread per AppKit) and `handleLlmProvisioning` (`@MainActor`).
        // `assumeIsolated` asserts that invariant rather than silently trusting it.
        guard let manager = MainActor.assumeIsolated({ ensureSidecarManager(model: model) }) else {
            return
        }

        let appLog = self.appLog
        Task {
            do {
                try await manager.startIfNeeded(model: model)
            } catch {
                appLog?.log("Failed to start the LLM Sidecar: \(error)", level: .error)
            }
        }
    }

    /// The single convergence point for `sidecarManagerInstance`: reuse the existing
    /// manager if one has already been constructed, or build+assign one. `@MainActor`
    /// so concurrent callers always observe or construct exactly *one* `SidecarManager`
    /// — the main-thread launch path (`startProductionSidecar`, above) and
    /// `resolveLiveSidecarEndpoint` (`AppCoordinator+CommandMode.swift`), which runs on
    /// the command router's own cooperative thread pool, not the main actor — instead
    /// of racing to each spawn their own `llama-server` (on a 16GB machine, each
    /// mmapping the full model: swap-thrashing territory).
    ///
    /// `SidecarLifecycleController.startIfNeeded` is already idempotent once callers
    /// share an instance (`guard lifecycleTask == nil`), so this only needs to fix
    /// *which* instance gets built and assigned — not re-implement that idempotency.
    @MainActor
    func ensureSidecarManager(model: ModelDescriptor) -> SidecarManager? {
        productionSidecarModel = model
        if let existing = sidecarManagerInstance {
            return existing
        }
        guard let logFileURL = storage?.sidecarLogFile,
            let binaryDirectory = Bundle.main.resourceURL?.appending(
                path: "llama-server", directoryHint: .isDirectory)
        else {
            appLog?.log(
                "LLM Sidecar not started — storage or the bundled llama-server resource is unavailable.",
                level: .error)
            return nil
        }
        let appLog = self.appLog
        let tierOverride = settings.modelTier.flatMap(Tier.init(rawValue:))
        let resolvedTier =
            tierOverride
            ?? TierPolicy.tier(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        // 16GB gets its own, shorter idle-unload threshold (Phase 6 policy update: the
        // resident Qwen3-8B costs ~4.7GB of RAM held indefinitely otherwise); 8GB keeps
        // `IdleUnloadPolicy.defaultIdleThreshold` (5min, unchanged).
        let idleUnloadThreshold: TimeInterval =
            resolvedTier == .tier16GB
            ? IdleUnloadPolicy.tier16IdleThreshold
            : IdleUnloadPolicy.defaultIdleThreshold
        let manager = SidecarManager(
            binaryDirectory: binaryDirectory,
            logFileURL: logFileURL,
            modelsDirectory: AppCoordinator.modelsDirectory,
            tier: resolvedTier,
            idleUnloadThreshold: idleUnloadThreshold,
            onStateChange: { state in
                appLog?.log("LLM Sidecar: state -> \(state)", level: .notice)
            })
        sidecarManagerInstance = manager
        return manager
    }

    /// `ensureSidecarManager(model:)`'s counterpart for Command Mode's router: resolves
    /// the Qwen descriptor, reuses `sidecarManagerInstance` if already built, or
    /// constructs one — gated on the model actually being provisioned on disk, exactly
    /// mirroring `startSidecarIfModelReady()`'s guard above — if not. `@MainActor` for
    /// the same reason as `ensureSidecarManager(model:)`: `resolveLiveSidecarEndpoint`
    /// calls this from the router's cooperative thread pool, never the main thread.
    @MainActor
    func ensureSidecarManagerIfModelProvisioned() -> (manager: SidecarManager, model: ModelDescriptor)? {
        let descriptor = resolvedLlmModelDescriptor
        if let existing = sidecarManagerInstance {
            return (existing, descriptor)
        }
        let blobURL = AppCoordinator.modelsDirectory.blobURL(for: descriptor)
        guard FileManager.default.fileExists(atPath: blobURL.path) else { return nil }
        guard let manager = ensureSidecarManager(model: descriptor) else { return nil }
        return (manager, descriptor)
    }

    /// Record an LLM request, resetting the idle-unload countdown (Phase 6; LLD §5.4).
    /// If the Sidecar was idle-unloaded (`.stopped`), restarts it — the normal
    /// `.launching` → `.ready` flow produces a brief visible loading state. Future LLM
    /// consumers (P4/P5/P6) call this before every request. Its only caller
    /// (`resolveLiveSidecarEndpoint`) runs off the main actor, so both
    /// `sidecarManagerInstance` and `productionSidecarModel` reads are hopped onto the
    /// main actor rather than read directly from that thread.
    func noteLLMActivity() {
        Task {
            guard let manager = await MainActor.run(body: { self.sidecarManagerInstance }) else {
                return
            }
            let appLog = self.appLog
            await manager.recordActivity()
            let state = await manager.state
            guard case .stopped = state else { return }
            guard let model = await MainActor.run(body: { self.productionSidecarModel }) else { return }
            appLog?.log("Idle-unload: reloading Sidecar on new LLM request.", level: .notice)
            do {
                try await manager.startIfNeeded(model: model)
            } catch {
                appLog?.log("Failed to restart Sidecar after idle-unload: \(error)", level: .error)
            }
        }
    }

    /// P2b Phase 2 (User Story 9): give the Sidecar's async teardown a chance to kill
    /// its `llama-server` child before the app actually exits — `.terminateLater` +
    /// `NSApp.reply(toApplicationShouldTerminate:)` is the only way to guarantee an
    /// async subprocess teardown completes before the process image goes away — a
    /// synchronous `applicationWillTerminate` can't `await`.
    func applicationShouldTerminate(_ completion: @escaping () -> Void) {
        guard let manager = sidecarManagerInstance else {
            completion()
            return
        }
        Task {
            await manager.stop()
            completion()
        }
    }
}

/// Everything `runSidecarCheckIfRequested()` needs to construct a `SidecarManager` and
/// launch it — bundled up so `resolveSidecarCheckConfig` can be a single early-return
/// helper (see that function's doc comment for why it exists).
private struct SidecarCheckConfig {
    let logFileURL: URL
    let binaryDirectory: URL
    let modelsDirectory: ModelsDirectory
    let descriptor: ModelDescriptor
}

/// Resolve the env-vars + storage into a `SidecarCheckConfig`, logging why and returning
/// `nil` if anything's missing. Split out of `runSidecarCheckIfRequested()` purely to
/// keep that function under SwiftLint's function-body-length ceiling — no behavior change.
private func resolveSidecarCheckConfig(
    env: [String: String], storage: StorageLayout?, appLog: AppLog?
) -> SidecarCheckConfig? {
    guard let modelPath = env["AIDE_SIDECAR_MODEL_PATH"], !modelPath.isEmpty else {
        appLog?.log("AIDE_RUN_SIDECAR_CHECK=1 but AIDE_SIDECAR_MODEL_PATH is unset — skipping.", level: .warning)
        return nil
    }
    guard let logFileURL = storage?.sidecarLogFile else {
        appLog?.log("Storage isn't set up yet — can't resolve logs/sidecar.log.", level: .error)
        return nil
    }
    // Dev override so this can be driven against Vendor/bin/llama-server without a full
    // signed .app build; falls back to the real bundled resource otherwise.
    let binaryDirectory =
        env["AIDE_SIDECAR_BINARY_DIR"].map { URL(fileURLWithPath: $0) }
        ?? Bundle.main.resourceURL?.appending(path: "llama-server", directoryHint: .isDirectory)
    guard let binaryDirectory else {
        appLog?.log("Could not resolve the bundled llama-server resource directory.", level: .error)
        return nil
    }

    // Real model provisioning is Phase 5's job; for now, resolve `ModelsDirectory` to the
    // manually-placed dev GGUF's own parent directory so `startIfNeeded` still goes
    // through the real `ModelDescriptor` -> path resolution path.
    let modelURL = URL(fileURLWithPath: modelPath)
    let modelsDirectory = ModelsDirectory(resolved: modelURL.deletingLastPathComponent())
    let descriptor = ModelDescriptor(
        repo: "dev-local",
        pinnedRevision: "dev",
        filename: modelURL.lastPathComponent,
        expectedSHA256: "",
        byteSize: 0,
        onDiskRelativePath: modelURL.lastPathComponent)

    return SidecarCheckConfig(
        logFileURL: logFileURL, binaryDirectory: binaryDirectory, modelsDirectory: modelsDirectory,
        descriptor: descriptor)
}

/// Poll `manager.state` (no real sleep budget wasted — `SidecarLifecycleController`
/// already logs every transition via `onStateChange`, this just waits for the terminal
/// one that matters here) until `.ready` yields a usable endpoint, `.failed` gives up, or
/// `timeout` elapses. An internal (module-wide) free function — kept out of
/// `AppCoordinator`'s extension to stay within SwiftLint's function-body-length ceiling.
func waitForSidecarReady(
    _ manager: SidecarManager,
    appLog: AppLog?,
    timeout: TimeInterval = 60
) async -> LLMEndpoint? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let state = await manager.state
        if case .ready = state, let endpoint = await manager.endpoint {
            return endpoint
        }
        if case .failed(let reason) = state {
            appLog?.log("Sidecar check: reached .failed(\(reason)) — skipping the debug chat() call.", level: .error)
            return nil
        }
        try? await Task.sleep(for: .milliseconds(300))
    }
    appLog?.log("Sidecar check: timed out waiting for .ready — skipping the debug chat() call.", level: .error)
    return nil
}

/// Fire one real `chat()` call against the live Sidecar through the real
/// `InferenceClient` and log the rendered completion — plan Phase 3's manual debug hook.
/// Called once with `stream: false` and once with `stream: true` so both wire modes are
/// actually exercised against the real binary, not just headlessly.
private func runDebugChat(endpoint: LLMEndpoint, stream: Bool, appLog: AppLog?) async {
    let client = InferenceClient()
    let mode = stream ? "streamed" : "non-streamed"
    do {
        let resultStream = try await client.chat(
            system: "You are a terse, friendly assistant running entirely on this Mac.",
            messages: [
                ChatMessage(
                    role: .user,
                    content: "In one short sentence, say hello and confirm you're running locally.")
            ],
            params: SamplingParams(temperature: 0.7, maxTokens: 64),
            endpoint: endpoint,
            stream: stream)

        var full = ""
        var chunkCount = 0
        for try await chunk in resultStream {
            full += chunk.delta
            chunkCount += 1
        }
        appLog?.log(
            "Sidecar check: debug chat() (\(mode), \(chunkCount) chunk(s)) completion: \"\(full)\"")
    } catch {
        appLog?.log("Sidecar check: debug chat() (\(mode)) failed: \(error)", level: .error)
    }
}
