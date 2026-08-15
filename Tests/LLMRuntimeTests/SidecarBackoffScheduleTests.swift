import XCTest

@testable import LLMRuntime

/// TDD for the pure backoff-schedule function (plan Phase 2 acceptance criteria):
/// correct `1,2,4,8,...` delay sequence capped at 30s; a healthy interval > 60s
/// resets the attempt count; exceeding max retries yields give-up. Time is injected
/// as a plain `TimeInterval` — no `Date()`, no sleeps, anywhere in this suite.
final class SidecarBackoffScheduleTests: XCTestCase {

    // MARK: - Delay sequence

    func testFirstFailureDelaysOneSecond() {
        guard
            case .retry(let delay, let attempt) = SidecarBackoffSchedule.decide(
                attempt: 0, timeSinceLastHealthy: nil)
        else {
            return XCTFail("expected a retry decision")
        }
        XCTAssertEqual(delay, 1)
        XCTAssertEqual(attempt, 1)
    }

    func testDelaySequenceDoublesThenCapsAtThirtySeconds() {
        // attempt: 0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7
        // delay:      1    2    4    8    16   30   30
        let expectedDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30, 30]
        var attempt = 0
        for expectedDelay in expectedDelays {
            guard
                case .retry(let delay, let nextAttempt) = SidecarBackoffSchedule.decide(
                    attempt: attempt, timeSinceLastHealthy: 5, maxAttempts: 100)
            else {
                return XCTFail("expected a retry decision")
            }
            XCTAssertEqual(delay, expectedDelay, "wrong delay for attempt \(attempt)")
            attempt = nextAttempt
        }
    }

    // MARK: - Reset after a long healthy interval

    func testHealthyIntervalOverSixtySecondsResetsAttemptCount() {
        guard
            case .retry(let delay, let attempt) = SidecarBackoffSchedule.decide(
                attempt: 5, timeSinceLastHealthy: 61)
        else {
            return XCTFail("expected a retry decision")
        }
        XCTAssertEqual(delay, 1, "a >60s healthy interval must reset the schedule to the first delay")
        XCTAssertEqual(attempt, 1)
    }

    func testHealthyIntervalOfExactlySixtySecondsDoesNotReset() {
        guard
            case .retry(let delay, _) = SidecarBackoffSchedule.decide(
                attempt: 3, timeSinceLastHealthy: 60)
        else {
            return XCTFail("expected a retry decision")
        }
        XCTAssertEqual(delay, 8, "exactly 60s is not '> 60s' — must not reset")
    }

    func testNeverHealthyDoesNotReset() {
        // nil means "never healthy this launch" — must still escalate toward give-up,
        // not perpetually retry at the first-attempt delay.
        guard
            case .retry(let delay, _) = SidecarBackoffSchedule.decide(
                attempt: 3, timeSinceLastHealthy: nil)
        else {
            return XCTFail("expected a retry decision")
        }
        XCTAssertEqual(delay, 8)
    }

    // MARK: - Give-up

    func testExceedingMaxRetriesGivesUp() {
        let decision = SidecarBackoffSchedule.decide(attempt: 6, timeSinceLastHealthy: 5, maxAttempts: 6)
        XCTAssertEqual(decision, .giveUp(attempts: 6))
    }

    func testTheMaxAttemptsAttemptItselfStillRetries() {
        guard
            case .retry(_, let attempt) = SidecarBackoffSchedule.decide(
                attempt: 5, timeSinceLastHealthy: 5, maxAttempts: 6)
        else {
            return XCTFail("the maxAttempts-th attempt should still be a retry, not a give-up")
        }
        XCTAssertEqual(attempt, 6)
    }

    func testResetAttemptCountCanStillReachGiveUpAfterEnoughNewFailures() {
        // A reset only clears the counter — it doesn't disable give-up.
        let decision = SidecarBackoffSchedule.decide(attempt: 99, timeSinceLastHealthy: 61, maxAttempts: 1)
        XCTAssertEqual(decision, .retry(delay: 1, attempt: 1), "the reset attempt should still be allowed")
        XCTAssertEqual(
            SidecarBackoffSchedule.decide(attempt: 1, timeSinceLastHealthy: 5, maxAttempts: 1),
            .giveUp(attempts: 1))
    }
}
