import Foundation

@testable import LLMRuntime
@testable import ModelProvisioning

// Shared fixtures/fakes for `SidecarLifecycleControllerTests` (split out per
// `file_length` — mirrors `Tests/ModelDownloaderTests/StubURLProtocol.swift`'s
// precedent of keeping a suite's fake infrastructure in its own file). None of these
// declarations are `private`: XCTest files in the same target see each other's
// internal (non-private) declarations, so the test file can reference them directly.

// MARK: - Fixtures

extension ModelDescriptor {
    static let fixture = ModelDescriptor(
        repo: "test/repo",
        pinnedRevision: "deadbeef",
        filename: "test-model.gguf",
        expectedSHA256: "",
        byteSize: 0,
        onDiskRelativePath: "test-model.gguf")
}

// MARK: - Fakes

/// A scriptable `SidecarProcessSource`: `launchOutcomes`/`healthOutcomes` are consumed
/// in order by call count, clamping to the last element once exhausted (so an
/// unscripted tail keeps returning the last configured outcome).
actor FakeSidecarProcessSource: SidecarProcessSource {
    enum LaunchOutcome {
        case succeed(port: Int)
        case fail
    }

    private var launchOutcomes: [LaunchOutcome]
    private var healthOutcomes: [Bool]
    private(set) var launchCount = 0
    private(set) var healthCheckCount = 0
    private(set) var terminateCount = 0

    init(launchOutcomes: [LaunchOutcome], healthOutcomes: [Bool]) {
        self.launchOutcomes = launchOutcomes
        self.healthOutcomes = healthOutcomes
    }

    func setOutcomes(launch: [LaunchOutcome], health: [Bool]) {
        launchOutcomes = launch
        healthOutcomes = health
        launchCount = 0
        healthCheckCount = 0
    }

    func launch(model: ModelDescriptor) async throws -> Int {
        launchCount += 1
        switch launchOutcomes[min(launchCount - 1, launchOutcomes.count - 1)] {
        case .succeed(let port): return port
        case .fail: throw FakeLaunchError()
        }
    }

    func checkHealth(port: Int) async -> Bool {
        healthCheckCount += 1
        return healthOutcomes[min(healthCheckCount - 1, healthOutcomes.count - 1)]
    }

    func terminate() async {
        terminateCount += 1
    }
}

private struct FakeLaunchError: Error {}

/// A virtual clock: `wait(for:)` advances `now()` by the requested duration and
/// yields the thread — a genuine `Task` suspension point (so the engine's background
/// loop can't monopolize the actor) — but never actually sleeps in wall-clock time.
final class FakeSidecarTiming: SidecarTiming, @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime = Date(timeIntervalSince1970: 0)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentTime
    }

    func wait(for duration: TimeInterval) async {
        advance(by: duration)
        await Task.yield()
    }

    /// A plain synchronous helper so the lock/unlock pair isn't called directly from
    /// `wait(for:)`'s async body (NSLock's `lock()`/`unlock()` are `noasync`).
    private func advance(by duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        currentTime = currentTime.addingTimeInterval(duration)
    }
}

/// Records every state the engine passed through, in order, via `onStateChange`.
final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SidecarState] = []

    func record(_ state: SidecarState) {
        lock.lock()
        defer { lock.unlock() }
        events.append(state)
    }

    private var snapshot: [SidecarState] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Cooperatively yield (never sleep) until at least `count` events have been
    /// recorded, or the attempt budget is exhausted.
    func wait(untilCountAtLeast count: Int, attempts: Int = 50_000) async -> [SidecarState] {
        await wait(attempts: attempts) { $0.count >= count }
    }

    func wait(attempts: Int = 50_000, _ predicate: ([SidecarState]) -> Bool) async -> [SidecarState] {
        for _ in 0..<attempts {
            let current = snapshot
            if predicate(current) { return current }
            await Task.yield()
        }
        return snapshot
    }
}

/// A general-purpose bounded, sleep-free poll used only for a plain boolean condition
/// (as opposed to `StateRecorder.wait`, which polls the recorded-events snapshot).
@discardableResult
func pollUntil(attempts: Int = 50_000, _ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<attempts {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}
