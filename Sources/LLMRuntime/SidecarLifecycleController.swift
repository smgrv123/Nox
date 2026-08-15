import Foundation
import ModelProvisioning

/// The full Sidecar lifecycle state machine (docs/05-lld.md §5.1 — normative; plan
/// Phase 2; User Stories 6, 7, 8, 9, 20) — generic over the injected
/// `SidecarProcessSource` (real `Process`/HTTP vs. a test fake) and `SidecarTiming`
/// (real clock/sleep vs. a test fake), so the entire `stopped -> launching -> ready ->
/// unhealthy -> failed` cycle — including the pure `SidecarBackoffSchedule` — is
/// exercised headlessly in `LLMRuntimeTests` with **no real process, no real network,
/// no real sleeps**.
///
/// `SidecarManager` (App/, plan Phase 2's "Architectural decisions") is this same type
/// configured with the real `llama-server` process source and a real wall-clock timer
/// — there is deliberately no second, parallel state-machine implementation for
/// production; the App layer only supplies real dependencies (see that file's doc
/// comment).
public actor SidecarLifecycleController: SidecarController {

    private let processSource: any SidecarProcessSource
    private let timing: any SidecarTiming
    private let maxAttempts: Int
    private let healthPollInterval: TimeInterval
    private let launchHealthTimeout: TimeInterval
    private let readyPollInterval: TimeInterval
    private let onStateChange: (@Sendable (SidecarState) -> Void)?

    public private(set) var state: SidecarState = .stopped

    private var currentModel: ModelDescriptor?
    private var attempt = 0
    private var lastHealthyAt: Date?
    private var lifecycleTask: Task<Void, Never>?

    /// - Parameters:
    ///   - processSource: the real or fake process/health-check seam.
    ///   - timing: the real or fake clock/sleep seam.
    ///   - maxAttempts: backoff give-up threshold (`SidecarBackoffSchedule.decide`).
    ///   - healthPollInterval: delay between health checks while waiting to become
    ///     `.ready` after a launch.
    ///   - launchHealthTimeout: how long to wait for a just-launched process to answer
    ///     healthy before treating the launch itself as a failure.
    ///   - readyPollInterval: delay between health checks while already `.ready`
    ///     (crash/hang detection — docs/05-lld.md §5.1: `Ready --> Unhealthy`).
    ///   - onStateChange: optional side-effect hook, invoked on every transition (the
    ///     App layer uses this to log timestamped transitions during manual
    ///     verification; tests use it to assert exact transition sequences).
    public init(
        processSource: any SidecarProcessSource,
        timing: any SidecarTiming = SystemSidecarTiming(),
        maxAttempts: Int = SidecarBackoffSchedule.defaultMaxAttempts,
        healthPollInterval: TimeInterval = 0.3,
        launchHealthTimeout: TimeInterval = 30,
        readyPollInterval: TimeInterval = 5,
        onStateChange: (@Sendable (SidecarState) -> Void)? = nil
    ) {
        self.processSource = processSource
        self.timing = timing
        self.maxAttempts = maxAttempts
        self.healthPollInterval = healthPollInterval
        self.launchHealthTimeout = launchHealthTimeout
        self.readyPollInterval = readyPollInterval
        self.onStateChange = onStateChange
    }

    // MARK: - SidecarController

    public var endpoint: LLMEndpoint? {
        guard case .ready(let port) = state, let currentModel else { return nil }
        return LLMEndpoint(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            model: currentModel.filename,
            isLocal: true)
    }

    public func startIfNeeded(model: ModelDescriptor) async throws {
        guard lifecycleTask == nil else { return }
        currentModel = model
        attempt = 0
        lastHealthyAt = nil
        beginLifecycle(model: model)
    }

    public func healthCheck() async -> Bool {
        guard case .ready(let port) = state else { return false }
        return await processSource.checkHealth(port: port)
    }

    public func restart() async {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        await processSource.terminate()
        attempt = 0
        lastHealthyAt = nil
        guard let model = currentModel else {
            setState(.stopped)
            return
        }
        beginLifecycle(model: model)
    }

    public func stop() async {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        await processSource.terminate()
        setState(.stopped)
    }

    public func swapModel(to model: ModelDescriptor) async throws {
        await stop()
        try await startIfNeeded(model: model)
    }

    // MARK: - Lifecycle loop

    private func beginLifecycle(model: ModelDescriptor) {
        lifecycleTask = Task { [weak self] in
            await self?.runLifecycle(model: model)
        }
    }

    /// One full pass: launch -> wait for healthy -> (poll while ready | fail) ->
    /// backoff -> repeat, until cancelled (`stop()`/`restart()`), or the backoff
    /// schedule gives up (`.failed`).
    private func runLifecycle(model: ModelDescriptor) async {
        while !Task.isCancelled {
            setState(.launching)

            var launchedPort: Int?
            do {
                launchedPort = try await processSource.launch(model: model)
            } catch {
                launchedPort = nil
            }
            guard !Task.isCancelled else { return }

            if let port = launchedPort, await waitForHealthy(port: port) {
                guard !Task.isCancelled else { return }
                setState(.ready(port: port))
                // Marks the *start* of this ready streak — deliberately NOT paired
                // with resetting `attempt` here. `SidecarBackoffSchedule.decide` is
                // the only place `attempt` resets, and only once this streak has
                // lasted > 60s (docs/05-lld.md §3.4). Resetting eagerly on every
                // momentary `.ready` would let a rapidly flapping Sidecar (crash,
                // relaunch, crash again within seconds) retry forever at the 1s floor
                // instead of escalating toward `.failed` — exactly the scenario the
                // "healthy interval > 60s" rule exists to distinguish from a
                // genuinely-recovered one.
                lastHealthyAt = timing.now()

                await pollWhileReady(port: port)
                guard !Task.isCancelled else { return }
            }

            // Reaching here means either the launch failed, health never came up, or
            // a ready Sidecar just failed a health check — in every case, make sure
            // nothing is left running before computing the next backoff step.
            await processSource.terminate()
            guard !Task.isCancelled else { return }
            guard await backoffOrGiveUp() else { return }
        }
    }

    /// Poll `checkHealth` every `healthPollInterval` until it succeeds or
    /// `launchHealthTimeout` elapses.
    private func waitForHealthy(port: Int) async -> Bool {
        let deadline = timing.now().addingTimeInterval(launchHealthTimeout)
        while timing.now() < deadline {
            if Task.isCancelled { return false }
            if await processSource.checkHealth(port: port) { return true }
            await timing.wait(for: healthPollInterval)
        }
        return false
    }

    /// While `.ready`, poll `checkHealth` every `readyPollInterval`; returns as soon as
    /// one fails (docs/05-lld.md §5.1: `Ready --> Unhealthy: health check fails /
    /// connection refused`) or the task is cancelled.
    private func pollWhileReady(port: Int) async {
        while !Task.isCancelled {
            await timing.wait(for: readyPollInterval)
            if Task.isCancelled { return }
            if !(await processSource.checkHealth(port: port)) { return }
        }
    }

    /// Consult the pure backoff schedule; either wait out the delay and return `true`
    /// (caller relaunches), or settle in `.failed` and return `false` (caller stops).
    private func backoffOrGiveUp() async -> Bool {
        let sinceHealthy = lastHealthyAt.map { timing.now().timeIntervalSince($0) }
        let decision = SidecarBackoffSchedule.decide(
            attempt: attempt, timeSinceLastHealthy: sinceHealthy, maxAttempts: maxAttempts)

        switch decision {
        case .retry(let delay, let nextAttempt):
            attempt = nextAttempt
            setState(.unhealthy(retryIn: delay))
            await timing.wait(for: delay)
            return true
        case .giveUp(let attempts):
            setState(.failed(reason: "Sidecar failed to become healthy after \(attempts) attempt(s)."))
            // The lifecycle loop is about to end on its own (not via stop()/restart(),
            // the only two places that otherwise clear this) — without this,
            // `lifecycleTask` stays non-nil forever, and startIfNeeded()'s `guard
            // lifecycleTask == nil` permanently no-ops even though the Task itself has
            // finished. Clearing it here (synchronously, no `await` between here and
            // `runLifecycle`'s `return`) is what lets a fresh startIfNeeded() — not
            // just an explicit restart() — recover from `.failed`, matching
            // docs/05-lld.md §5.1: `Failed --> Launching: manual retry / next request`.
            lifecycleTask = nil
            return false
        }
    }

    private func setState(_ newState: SidecarState) {
        state = newState
        onStateChange?(newState)
    }
}
