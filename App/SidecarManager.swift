import Foundation
import LLMRuntime
import ModelProvisioning

/// The real `SidecarController` conformer (plan Phase 2; User Stories 6, 7, 8, 9).
///
/// `SidecarManager` **is** `LLMRuntime.SidecarLifecycleController` — the full
/// lifecycle state machine (spawn -> health-poll -> ready -> backoff-restart ->
/// failed, docs/05-lld.md §5.1) already lives there, generic over the injected
/// `SidecarProcessSource` seam specifically so it can be driven test-first with a fake
/// in `LLMRuntimeTests`, with zero real process/network (see that type's doc comment).
/// This file supplies the one thing a test double can't: the *real* dependencies —
/// `LlamaServerProcessSource`'s actual `llama-server` `Process` spawn/health-poll/kill
/// mechanics (absorbed from Phase 1's `LlamaServerSidecarSpike`, now retired) and a
/// real wall-clock timer (`SystemSidecarTiming`, the engine's default) for actual
/// restart delays.
///
/// There is deliberately **no second, parallel state-machine implementation** here —
/// this is the plan's "Architectural decisions" placing `SidecarManager` in the App/
/// layer as a thin effectful shell (the same precedent as P1's `CGEventTap` / P2a's
/// `AudioCapture`), not a duplicate of the tested engine.
typealias SidecarManager = SidecarLifecycleController

extension SidecarLifecycleController {
    /// Construct the real Sidecar manager.
    /// - Parameters:
    ///   - binaryDirectory: where the bundled `llama-server` + its sibling dylibs live
    ///     (`Bundle.main.resourceURL` in production).
    ///   - logFileURL: `logs/sidecar.log` (`StorageLayout.sidecarLogFile`).
    ///   - modelsDirectory: resolves a `ModelDescriptor` to an absolute blob path.
    ///     Real provisioning is Phase 5's job — Phase 2's manual verification hook
    ///     (`AppCoordinator+Sidecar.swift`) points this at a manually-placed dev GGUF.
    ///   - tier: the confirmed model tier (Phase 6). When set, the Sidecar idle-unloads
    ///     after `idleUnloadThreshold` has elapsed with no activity; `nil` stays
    ///     resident (backwards-compatible with pre-Phase-6 callers).
    ///   - idleUnloadThreshold: seconds of inactivity before the Sidecar idle-unloads
    ///     (defaults to `IdleUnloadPolicy.defaultIdleThreshold`, the 8GB production
    ///     value; the 16GB call site passes `IdleUnloadPolicy.tier16IdleThreshold`
    ///     explicitly — see `AppCoordinator+Sidecar.swift`'s `ensureSidecarManager(model:)`).
    ///   - onStateChange: optional transition observer (used to log timestamped
    ///     state changes during manual verification).
    init(
        binaryDirectory: URL,
        logFileURL: URL,
        modelsDirectory: ModelsDirectory,
        tier: Tier? = nil,
        idleUnloadThreshold: TimeInterval = IdleUnloadPolicy.defaultIdleThreshold,
        onStateChange: (@Sendable (SidecarState) -> Void)? = nil
    ) {
        self.init(
            processSource: LlamaServerProcessSource(
                binaryDirectory: binaryDirectory, logFileURL: logFileURL, modelsDirectory: modelsDirectory),
            tier: tier,
            idleUnloadThreshold: idleUnloadThreshold,
            onStateChange: onStateChange)
    }
}
