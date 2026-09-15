import AideCore
import DangerousCommandScanner
import SpeechToText
import XCTest

@testable import Dictation

/// Confirm-Back's safety-net timeout (`VoiceSessionCoordinator
/// .scheduleConfirmBackTimeoutToIdle`) calls `driver.confirmBackTimedOut()`, not
/// `reject()` — the live-use bug this covers: the prompt could be dismissed by the
/// timeout before the user got to Approve, and the dictated text was simply gone.
/// `confirmBackTimedOut()` must never insert (the safety guarantee is unchanged) but
/// must not just drop the text either — it copies it to the clipboard, the same
/// escape hatch a failed AX insert already uses.
@MainActor
extension DictationDriverTests {

    func testConfirmBackTimedOutCopiesToClipboardAndNeverInserts() async {
        let setup = terminalSetup(verdict: .confirm(findings: [confirmFinding()]))
        let inserter = setup.inserter
        let driver = setup.driver

        var updates: [VoiceSessionUpdate] = []
        let confirmed = expectation(description: "confirm-back")
        let timedOut = expectation(description: "timed-out result")
        driver.onUpdate = { update in
            updates.append(update)
            if case .confirmBack = update { confirmed.fulfill() }
            if case .result = update { timedOut.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [confirmed], timeout: 2)

        driver.confirmBackTimedOut()
        await fulfillment(of: [timedOut], timeout: 2)

        XCTAssertTrue(inserter.inserted.isEmpty, "a timeout must never insert — the safety guarantee holds")
        XCTAssertEqual(inserter.copied, ["hello world"], "the dictated text must be preserved, not lost")
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: DictationDriver.confirmBackTimedOutSummary)))
    }

    func testConfirmBackTimedOutWithNoPendingInsertIsANoOp() async {
        let capture = FakeCaptureBuffer(finalizeReturns: dictationTestPCM)
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: capture,
            inserter: inserter)

        let noUpdate = expectation(description: "no update from a stray timeout")
        noUpdate.isInverted = true
        driver.onUpdate = { _ in noUpdate.fulfill() }

        driver.confirmBackTimedOut()

        await fulfillment(of: [noUpdate], timeout: 0.5)
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertTrue(inserter.copied.isEmpty)
    }

    func testConfirmBackTimedOutAfterANewSessionStartedIsANoOp() async {
        let setup = terminalSetup(verdict: .confirm(findings: [confirmFinding()]))
        let inserter = setup.inserter
        let driver = setup.driver

        let confirmed = expectation(description: "confirm-back")
        driver.onUpdate = { update in
            if case .confirmBack = update { confirmed.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [confirmed], timeout: 2)

        // A fresh PTT press (`begin`) clears the stash and bumps the generation —
        // the stale timeout for the superseded session must not fire on it.
        driver.begin(mode: .dictation)

        let noUpdate = expectation(description: "no update from the stale timeout")
        noUpdate.isInverted = true
        driver.onUpdate = { _ in noUpdate.fulfill() }

        driver.confirmBackTimedOut()

        await fulfillment(of: [noUpdate], timeout: 0.5)
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertTrue(inserter.copied.isEmpty)
    }
}
