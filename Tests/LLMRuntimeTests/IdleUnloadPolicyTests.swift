import XCTest

@testable import LLMRuntime
@testable import ModelProvisioning

/// TDD for the pure idle-unload state machine (plan Phase 6 acceptance criteria;
/// LLD §5.4; User Stories 16, 17, 18). Given (Tier, time since last request) →
/// resident/unload decision: 16GB never unloads; 8GB unloads after the idle threshold
/// elapses with no intervening activity; any activity resets the timer. Time is
/// injected as a plain `TimeInterval` — no `Date()`, no sleeps, anywhere in this suite.
final class IdleUnloadPolicyTests: XCTestCase {

    // MARK: - 8GB tier: idle time exceeds threshold → "unload"

    func testTier8GBIdleExceedsThresholdReturnsUnload() {
        let decision = IdleUnloadPolicy.decide(
            tier: .tier8GB,
            idleInterval: 301,
            threshold: 300)
        XCTAssertEqual(decision, .unload)
    }

    // MARK: - 8GB tier: activity before threshold → stays resident

    func testTier8GBIdleBelowThresholdReturnsResident() {
        let decision = IdleUnloadPolicy.decide(
            tier: .tier8GB,
            idleInterval: 100,
            threshold: 300)
        XCTAssertEqual(decision, .resident)
    }

    // MARK: - 8GB tier: activity resets, then idle again past threshold → "unload"

    func testTier8GBActivityResetsIdleThenExceedsThresholdUnloads() {
        let firstDecision = IdleUnloadPolicy.decide(
            tier: .tier8GB,
            idleInterval: 200,
            threshold: 300)
        XCTAssertEqual(firstDecision, .resident, "activity before threshold keeps it resident")

        let afterResetDecision = IdleUnloadPolicy.decide(
            tier: .tier8GB,
            idleInterval: 301,
            threshold: 300)
        XCTAssertEqual(afterResetDecision, .unload, "after activity resets timer and idle exceeds threshold, unloads")
    }

    // MARK: - 16GB tier: idle time exceeds threshold → still "resident"

    func testTier16GBIdleExceedsThresholdReturnsResident() {
        let decision = IdleUnloadPolicy.decide(
            tier: .tier16GB,
            idleInterval: 99_999,
            threshold: 300)
        XCTAssertEqual(decision, .resident)
    }

    // MARK: - 16GB tier: any idle duration → always resident

    func testTier16GBAlwaysResidentRegardlessOfIdleDuration() {
        for idleInterval: TimeInterval in [0, 1, 60, 300, 600, 3600, 86_400] {
            let decision = IdleUnloadPolicy.decide(
                tier: .tier16GB,
                idleInterval: idleInterval,
                threshold: 300)
            XCTAssertEqual(
                decision, .resident,
                "16GB tier must always be .resident, but got \(decision) at idle \(idleInterval)s")
        }
    }

    // MARK: - Edge: exactly at threshold boundary

    func testTier8GBExactlyAtThresholdStaysResident() {
        let decision = IdleUnloadPolicy.decide(
            tier: .tier8GB,
            idleInterval: 300,
            threshold: 300)
        XCTAssertEqual(decision, .resident, "exactly at threshold is not 'exceeds' — must stay resident")
    }

    func testTier8GBOneNanosecondPastThresholdUnloads() {
        let decision = IdleUnloadPolicy.decide(
            tier: .tier8GB,
            idleInterval: 300.000_000_001,
            threshold: 300)
        XCTAssertEqual(decision, .unload)
    }

    // MARK: - Edge: zero idle interval (just-used)

    func testTier8GBZeroIdleReturnsResident() {
        let decision = IdleUnloadPolicy.decide(
            tier: .tier8GB,
            idleInterval: 0,
            threshold: 300)
        XCTAssertEqual(decision, .resident)
    }

    // MARK: - Default threshold

    func testDefaultThresholdIsFiveMinutes() {
        XCTAssertEqual(IdleUnloadPolicy.defaultIdleThreshold, 300)
    }

    func testDecideUsesDefaultThresholdWhenNotSpecified() {
        let resident = IdleUnloadPolicy.decide(tier: .tier8GB, idleInterval: 299)
        XCTAssertEqual(resident, .resident)

        let unloaded = IdleUnloadPolicy.decide(tier: .tier8GB, idleInterval: 301)
        XCTAssertEqual(unloaded, .unload)
    }
}
