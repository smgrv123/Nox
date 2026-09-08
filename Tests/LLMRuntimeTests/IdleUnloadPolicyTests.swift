import XCTest

@testable import LLMRuntime
@testable import ModelProvisioning

/// TDD for the pure idle-unload state machine (plan Phase 6 acceptance criteria; LLD
/// §5.4, updated by a deliberate policy change superseding the prior "16GB always
/// resident" spec; User Stories 16, 17, 18). Given (Tier, time since last request) →
/// resident/unload decision: both tiers unload once their own idle threshold elapses
/// with no intervening activity (16GB at `tier16IdleThreshold`/180s, 8GB at
/// `defaultIdleThreshold`/300s); any activity resets the timer. Time is injected as a
/// plain `TimeInterval` — no `Date()`, no sleeps, anywhere in this suite.
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

    // MARK: - 16GB tier: idle time exceeds its threshold → "unload"

    func testTier16GBIdleExceedsThresholdReturnsUnload() {
        let decision = IdleUnloadPolicy.decide(
            tier: .tier16GB,
            idleInterval: 181,
            threshold: IdleUnloadPolicy.tier16IdleThreshold)
        XCTAssertEqual(decision, .unload)
    }

    // MARK: - 16GB tier: activity before threshold → stays resident

    func testTier16GBIdleBelowThresholdReturnsResident() {
        let decision = IdleUnloadPolicy.decide(
            tier: .tier16GB,
            idleInterval: 100,
            threshold: IdleUnloadPolicy.tier16IdleThreshold)
        XCTAssertEqual(decision, .resident)
    }

    // MARK: - 16GB tier: activity resets, then idle again past threshold → "unload"

    func testTier16GBActivityResetsIdleThenExceedsThresholdUnloads() {
        let firstDecision = IdleUnloadPolicy.decide(
            tier: .tier16GB,
            idleInterval: 120,
            threshold: IdleUnloadPolicy.tier16IdleThreshold)
        XCTAssertEqual(firstDecision, .resident, "activity before threshold keeps it resident")

        let afterResetDecision = IdleUnloadPolicy.decide(
            tier: .tier16GB,
            idleInterval: 181,
            threshold: IdleUnloadPolicy.tier16IdleThreshold)
        XCTAssertEqual(afterResetDecision, .unload, "after activity resets timer and idle exceeds threshold, unloads")
    }

    // MARK: - 16GB tier: production threshold constant is 3 minutes

    func testTier16IdleThresholdIsThreeMinutes() {
        XCTAssertEqual(IdleUnloadPolicy.tier16IdleThreshold, 180)
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
