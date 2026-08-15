import XCTest

@testable import LLMRuntime
@testable import ModelProvisioning

/// TDD for the Sidecar lifecycle state machine (plan Phase 2 acceptance criteria):
/// `stopped -> launching -> ready`, `ready -> unhealthy -> launching`, `unhealthy ->
/// failed`, and `stop()`/`restart()` from any state — driven entirely by an injected
/// fake `SidecarProcessSource` + a fake virtual-clock `SidecarTiming`. **No real
/// `Process`, no real network, no real sleeps** anywhere in this suite: the fake
/// timing's `wait(for:)` advances its own virtual clock and yields the thread instead
/// of actually sleeping, so a 30s health-poll timeout or a 30s backoff wait resolves
/// in a handful of scheduler ticks.
final class SidecarLifecycleControllerTests: XCTestCase {

    // MARK: - stopped -> launching -> ready

    func testStoppedLaunchingReady() async throws {
        let source = FakeSidecarProcessSource(launchOutcomes: [.succeed(port: 5555)], healthOutcomes: [true])
        let recorder = StateRecorder()
        let engine = SidecarLifecycleController(
            processSource: source, timing: FakeSidecarTiming(),
            onStateChange: { [recorder] state in recorder.record(state) })

        let initialState = await engine.state
        XCTAssertEqual(initialState, .stopped)
        let initialEndpoint = await engine.endpoint
        XCTAssertNil(initialEndpoint)

        try await engine.startIfNeeded(model: .fixture)

        let events = await recorder.wait(untilCountAtLeast: 2)
        XCTAssertEqual(events.first, .launching)
        guard case .ready(let port) = events.last else {
            return XCTFail("expected the second observed state to be .ready, got \(String(describing: events.last))")
        }
        XCTAssertEqual(port, 5555)

        let endpoint = await engine.endpoint
        XCTAssertEqual(endpoint?.baseURL, URL(string: "http://127.0.0.1:5555"))
        XCTAssertEqual(endpoint?.isLocal, true)

        await engine.stop()  // stop the still-spinning ready-poll loop before teardown
    }

    // MARK: - ready -> unhealthy -> launching -> ready (transient recovery)

    func testReadyToUnhealthyToLaunchingRecovers() async throws {
        let source = FakeSidecarProcessSource(
            launchOutcomes: [.succeed(port: 100), .succeed(port: 200)],
            // 1st check (waitForHealthy after launch #1) -> ready(100)
            // 2nd check (pollWhileReady's first check)    -> unhealthy -> relaunch
            // 3rd check (waitForHealthy after launch #2)  -> ready(200)
            healthOutcomes: [true, false, true])
        let recorder = StateRecorder()
        let engine = SidecarLifecycleController(
            processSource: source, timing: FakeSidecarTiming(),
            onStateChange: { [recorder] state in recorder.record(state) })

        try await engine.startIfNeeded(model: .fixture)

        let events = await recorder.wait(untilCountAtLeast: 5)
        XCTAssertEqual(
            events,
            [
                .launching,
                .ready(port: 100),
                .unhealthy(retryIn: 1),
                .launching,
                .ready(port: 200),
            ])

        await engine.stop()
    }

    /// Regression coverage for a real bug caught during Phase 2's live crash/restart
    /// verification: repeatedly killing the real `llama-server` process the instant it
    /// came back up never escalated the backoff delay and never reached `.failed` — a
    /// premature `attempt = 0` reset on every `.ready` transition was defeating the
    /// "healthy interval > 60s resets the attempt count" rule (docs/05-lld.md §3.4). A
    /// *momentary* ready streak (well under 60s here) must **not** reset the counter —
    /// each rapid re-failure should escalate the delay exactly like a Sidecar that
    /// never became ready at all.
    func testRapidReFailureAfterAShortReadyStreakStillEscalatesBackoff() async throws {
        let source = FakeSidecarProcessSource(
            launchOutcomes: [.succeed(port: 1), .succeed(port: 2), .succeed(port: 3)],
            // Each launch becomes briefly ready, then immediately fails its first
            // ready-poll check — a "flapping" Sidecar, never healthy long enough to
            // forgive the prior failure.
            healthOutcomes: [true, false, true, false, true, false])
        let recorder = StateRecorder()
        let engine = SidecarLifecycleController(
            processSource: source,
            timing: FakeSidecarTiming(),
            maxAttempts: 10,
            readyPollInterval: 1,  // well under the 60s reset threshold
            onStateChange: { [recorder] state in recorder.record(state) })

        try await engine.startIfNeeded(model: .fixture)

        let events = await recorder.wait { events in
            events.filter {
                if case .unhealthy = $0 { return true }
                return false
            }.count >= 3
        }
        let unhealthyDelays: [TimeInterval] = events.compactMap {
            if case .unhealthy(let retryIn) = $0 { return retryIn }
            return nil
        }
        XCTAssertEqual(
            unhealthyDelays, [1, 2, 4],
            "each rapid re-failure must escalate the backoff, not reset to the 1s floor")

        await engine.stop()
    }

    // MARK: - unhealthy -> failed (max retries exceeded)

    func testRepeatedFailuresGiveUpAndSurfaceFailed() async throws {
        // Every launch "succeeds" (returns a port) but the server never answers
        // healthy — with launchHealthTimeout == healthPollInterval, each launch
        // attempt fails after exactly one health check.
        let source = FakeSidecarProcessSource(launchOutcomes: [.succeed(port: 1)], healthOutcomes: [false])
        let recorder = StateRecorder()
        let engine = SidecarLifecycleController(
            processSource: source,
            timing: FakeSidecarTiming(),
            maxAttempts: 3,
            healthPollInterval: 1,
            launchHealthTimeout: 1,
            onStateChange: { [recorder] state in recorder.record(state) })

        try await engine.startIfNeeded(model: .fixture)

        let events = await recorder.wait { events in
            if case .failed = events.last { return true }
            return false
        }

        XCTAssertEqual(
            events,
            [
                .launching,  // attempt 1: fails
                .unhealthy(retryIn: 1),
                .launching,  // attempt 2: fails
                .unhealthy(retryIn: 2),
                .launching,  // attempt 3: fails
                .unhealthy(retryIn: 4),
                .launching,  // attempt 4: fails -> exceeds maxAttempts (3) -> give up
                .failed(reason: "Sidecar failed to become healthy after 3 attempt(s)."),
            ])

        let finalState = await engine.state
        XCTAssertEqual(finalState, .failed(reason: "Sidecar failed to become healthy after 3 attempt(s)."))
    }

    // MARK: - manual restart() recovers from .failed

    func testRestartRecoversFromFailed() async throws {
        let source = FakeSidecarProcessSource(launchOutcomes: [.succeed(port: 1)], healthOutcomes: [false])
        let recorder = StateRecorder()
        let engine = SidecarLifecycleController(
            processSource: source,
            timing: FakeSidecarTiming(),
            maxAttempts: 1,
            healthPollInterval: 1,
            launchHealthTimeout: 1,
            onStateChange: { [recorder] state in recorder.record(state) })

        try await engine.startIfNeeded(model: .fixture)
        _ = await recorder.wait { events in
            if case .failed = events.last { return true }
            return false
        }

        await source.setOutcomes(launch: [.succeed(port: 999)], health: [true])
        await engine.restart()

        let recoveredEvents = await recorder.wait { events in
            if case .ready = events.last { return true }
            return false
        }
        XCTAssertEqual(recoveredEvents.last, .ready(port: 999))

        await engine.stop()
    }

    // MARK: - startIfNeeded() also recovers from .failed (not just restart())

    /// Regression test: before the fix, `lifecycleTask` was cleared to `nil` only
    /// inside `restart()`/`stop()` — never at the point `runLifecycle`'s own backoff
    /// loop gives up and settles into `.failed`. That left a finished-but-non-nil
    /// `Task` behind, so `startIfNeeded()`'s `guard lifecycleTask == nil` permanently
    /// no-opped on every subsequent call; only an explicit `restart()` could recover.
    /// docs/05-lld.md §5.1 names `Failed --> Launching: manual retry / next request`
    /// as *two* distinct recovery paths — this proves the "next request" (a fresh
    /// `startIfNeeded()`) half also works, mirroring `testRestartRecoversFromFailed`
    /// above but calling `startIfNeeded(model:)` again instead of `restart()`.
    func testStartIfNeededRecoversFromFailed() async throws {
        let source = FakeSidecarProcessSource(launchOutcomes: [.succeed(port: 1)], healthOutcomes: [false])
        let recorder = StateRecorder()
        let engine = SidecarLifecycleController(
            processSource: source,
            timing: FakeSidecarTiming(),
            maxAttempts: 1,
            healthPollInterval: 1,
            launchHealthTimeout: 1,
            onStateChange: { [recorder] state in recorder.record(state) })

        try await engine.startIfNeeded(model: .fixture)
        _ = await recorder.wait { events in
            if case .failed = events.last { return true }
            return false
        }

        await source.setOutcomes(launch: [.succeed(port: 999)], health: [true])
        try await engine.startIfNeeded(model: .fixture)  // not restart() — this is the bug's exact repro

        let recoveredEvents = await recorder.wait { events in
            if case .ready = events.last { return true }
            return false
        }
        XCTAssertEqual(recoveredEvents.last, .ready(port: 999))

        await engine.stop()
    }

    // MARK: - stop() from any state settles .stopped and terminates the process

    func testStopFromReadySettlesStoppedAndTerminatesProcess() async throws {
        let source = FakeSidecarProcessSource(launchOutcomes: [.succeed(port: 1)], healthOutcomes: [true])
        let recorder = StateRecorder()
        let engine = SidecarLifecycleController(
            processSource: source, timing: FakeSidecarTiming(),
            onStateChange: { [recorder] state in recorder.record(state) })

        try await engine.startIfNeeded(model: .fixture)
        _ = await recorder.wait { events in
            if case .ready = events.last { return true }
            return false
        }

        await engine.stop()

        let finalState = await engine.state
        XCTAssertEqual(finalState, .stopped)
        let finalEndpoint = await engine.endpoint
        XCTAssertNil(finalEndpoint)
        let terminateCount = await source.terminateCount
        XCTAssertGreaterThanOrEqual(terminateCount, 1)
    }

    // MARK: - startIfNeeded is idempotent

    func testStartIfNeededIsIdempotentWhileAlreadyRunning() async throws {
        let source = FakeSidecarProcessSource(launchOutcomes: [.succeed(port: 1)], healthOutcomes: [true])
        let engine = SidecarLifecycleController(processSource: source, timing: FakeSidecarTiming())

        try await engine.startIfNeeded(model: .fixture)
        try await engine.startIfNeeded(model: .fixture)  // must be a no-op, not a second loop

        let reachedReady = await pollUntil {
            if case .ready = await engine.state { return true }
            return false
        }
        XCTAssertTrue(reachedReady, "the single lifecycle loop should still reach .ready")

        let launchCount = await source.launchCount
        XCTAssertEqual(launchCount, 1, "a second startIfNeeded while running must not spawn a second loop")

        await engine.stop()
    }
}

// MARK: - Fixtures & Fakes
//
// Shared fixtures (`ModelDescriptor.fixture`) and fakes (`FakeSidecarProcessSource`,
// `FakeSidecarTiming`, `StateRecorder`, `pollUntil`) live in
// `SidecarLifecycleControllerFixtures.swift`, a sibling file in this target.
