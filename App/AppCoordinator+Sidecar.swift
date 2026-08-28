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
/// The manager's handle is a file-private global, not an `AppCoordinator` stored
/// property: `AppCoordinator.swift` is already at SwiftLint's file-length ceiling, and
/// neither caller needs it visible outside this file.
private var sidecarManagerInstance: SidecarManager?

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
    func startProductionSidecar(model: ModelDescriptor) {
        let manager: SidecarManager
        if let existing = sidecarManagerInstance {
            manager = existing
        } else {
            guard let logFileURL = storage?.sidecarLogFile,
                let binaryDirectory = Bundle.main.resourceURL?.appending(
                    path: "llama-server", directoryHint: .isDirectory)
            else {
                appLog?.log(
                    "LLM Sidecar not started — storage or the bundled llama-server resource is unavailable.",
                    level: .error)
                return
            }
            let appLog = self.appLog
            manager = SidecarManager(
                binaryDirectory: binaryDirectory,
                logFileURL: logFileURL,
                modelsDirectory: AppCoordinator.modelsDirectory,
                onStateChange: { state in
                    appLog?.log("LLM Sidecar: state -> \(state)", level: .notice)
                })
            sidecarManagerInstance = manager
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
/// `timeout` elapses. A free function, not an `AppCoordinator` method, for the same
/// file-length reason `sidecarManagerInstance` is a file-private global above.
private func waitForSidecarReady(
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
