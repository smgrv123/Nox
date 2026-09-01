import XCTest

@testable import LLMRuntime
@testable import ModelProvisioning

/// TDD for idle-unload behavior integrated into `SidecarLifecycleController` (plan
/// Phase 6; LLD §5.4; User Stories 16, 17, 18). These tests verify that the lifecycle
/// engine, when configured with a `Tier`, applies `IdleUnloadPolicy` during its
/// ready-poll loop — stopping cleanly (`.stopped`, not `.failed`) when the 8GB tier's
/// idle threshold is exceeded, and never stopping for 16GB.
///
/// Reuses the same `FakeSidecarProcessSource`/`FakeSidecarTiming`/`StateRecorder`
/// fixtures from `SidecarLifecycleControllerFixtures.swift`.
final class IdleUnloadLifecycleTests: XCTestCase {

    // MARK: - 8GB tier: idle-unloads after threshold

    func testTier8GBIdleUnloadsAfterThreshold() async throws {
        let source = FakeSidecarProcessSource(
            launchOutcomes: [.succeed(port: 5000)], healthOutcomes: [true])
        let timing = FakeSidecarTiming()
        let recorder = StateRecorder()
        let engine = SidecarLifecycleController(
            processSource: source,
            timing: timing,
            readyPollInterval: 10,
            tier: .tier8GB,
            idleUnloadThreshold: 25,
            onStateChange: { [recorder] state in recorder.record(state) })

        try await engine.startIfNeeded(model: .fixture)

        let events = await recorder.wait { events in
            if case .stopped = events.last { return true }
            return false
        }

        XCTAssertEqual(events.first, .launching)
        XCTAssertTrue(events.contains(.ready(port: 5000)))
        XCTAssertEqual(events.last, .stopped, "8GB tier must idle-unload to .stopped")

        let finalState = await engine.state
        XCTAssertEqual(finalState, .stopped)
    }

    // MARK: - 8GB tier: activity resets idle timer, stays resident

    func testTier8GBActivityResetsIdleTimerStaysResident() async throws {
        let source = FakeSidecarProcessSource(
            launchOutcomes: [.succeed(port: 5000)], healthOutcomes: [true])
        let recorder = StateRecorder()

        // readyPollInterval (5s) << idleUnloadThreshold (100s): even in the worst case
        // (the first poll fires before the test's recordActivity() runs), the idle
        // interval after one poll is only 5s — well under the 100s threshold. After
        // recordActivity(), every subsequent idle check sees at most 5s since last
        // activity, so the engine stays resident through many iterations.
        let engine = SidecarLifecycleController(
            processSource: source,
            timing: FakeSidecarTiming(),
            readyPollInterval: 5,
            tier: .tier8GB,
            idleUnloadThreshold: 100,
            onStateChange: { [recorder] state in recorder.record(state) })

        try await engine.startIfNeeded(model: .fixture)

        _ = await recorder.wait(untilCountAtLeast: 2)

        await engine.recordActivity()

        let reachedReady = await pollUntil {
            if case .ready = await engine.state { return true }
            return false
        }
        XCTAssertTrue(reachedReady, "activity should keep the Sidecar in .ready state")

        await engine.stop()
    }

    // MARK: - 16GB tier: never idle-unloads

    func testTier16GBNeverIdleUnloads() async throws {
        let source = FakeSidecarProcessSource(
            launchOutcomes: [.succeed(port: 6000)], healthOutcomes: [true])
        let timing = FakeSidecarTiming()
        let recorder = StateRecorder()
        let engine = SidecarLifecycleController(
            processSource: source,
            timing: timing,
            readyPollInterval: 100,
            tier: .tier16GB,
            idleUnloadThreshold: 50,
            onStateChange: { [recorder] state in recorder.record(state) })

        try await engine.startIfNeeded(model: .fixture)

        let events = await recorder.wait(untilCountAtLeast: 2)
        XCTAssertEqual(events.first, .launching)
        XCTAssertEqual(events.last, .ready(port: 6000))

        let state = await engine.state
        XCTAssertEqual(state, .ready(port: 6000), "16GB tier must never idle-unload")

        await engine.stop()
    }

    // MARK: - After idle-unload, startIfNeeded relaunches

    func testStartIfNeededRelaunchesAfterIdleUnload() async throws {
        let source = FakeSidecarProcessSource(
            launchOutcomes: [.succeed(port: 7000), .succeed(port: 7001)],
            healthOutcomes: [true])
        let timing = FakeSidecarTiming()
        let recorder = StateRecorder()
        let engine = SidecarLifecycleController(
            processSource: source,
            timing: timing,
            readyPollInterval: 10,
            tier: .tier8GB,
            idleUnloadThreshold: 15,
            onStateChange: { [recorder] state in recorder.record(state) })

        try await engine.startIfNeeded(model: .fixture)

        _ = await recorder.wait { events in
            if case .stopped = events.last { return true }
            return false
        }

        let stoppedState = await engine.state
        XCTAssertEqual(stoppedState, .stopped, "should be idle-unloaded")

        try await engine.startIfNeeded(model: .fixture)

        let relaunchEvents = await recorder.wait { events in
            events.filter {
                if case .ready(let port) = $0 { return port == 7001 }
                return false
            }.count >= 1
        }

        let lastReady = relaunchEvents.last {
            if case .ready = $0 { return true }
            return false
        }
        XCTAssertEqual(lastReady, .ready(port: 7001), "should relaunch after idle-unload")

        await engine.stop()
    }

    // MARK: - No tier set: no idle-unload (backwards-compatible)

    func testNoTierSetNeverIdleUnloads() async throws {
        let source = FakeSidecarProcessSource(
            launchOutcomes: [.succeed(port: 8000)], healthOutcomes: [true])
        let timing = FakeSidecarTiming()
        let recorder = StateRecorder()
        let engine = SidecarLifecycleController(
            processSource: source,
            timing: timing,
            readyPollInterval: 100,
            onStateChange: { [recorder] state in recorder.record(state) })

        try await engine.startIfNeeded(model: .fixture)

        let events = await recorder.wait(untilCountAtLeast: 2)
        XCTAssertEqual(events.last, .ready(port: 8000))

        let state = await engine.state
        XCTAssertEqual(state, .ready(port: 8000), "no tier set — must not idle-unload")

        await engine.stop()
    }
}
