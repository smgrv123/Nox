import AideCore
import DangerousCommandScanner
import SpeechToText
import XCTest

@testable import Dictation

@MainActor
extension DictationDriverTests {

    func testNonTerminalDoesNotScan() async {
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.apple.TextEdit", accessibilityTrusted: true)
        let scanner = RecordingCommandScanner()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            scanner: scanner)

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(scanner.scanCallCount, 0)
        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
    }

    func testTerminalConfirmDoesNotInsertUntilApprove() async {
        let setup = terminalSetup(verdict: .confirm(findings: [confirmFinding()]))
        let inserter = setup.inserter
        let scanner = setup.scanner
        let driver = setup.driver

        var updates: [VoiceSessionUpdate] = []
        let confirmed = expectation(description: "confirm-back")
        driver.onUpdate = { update in
            updates.append(update)
            if case .confirmBack = update { confirmed.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [confirmed], timeout: 2)

        XCTAssertTrue(inserter.inserted.isEmpty, "zero characters inserted until Approve")
        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(scanner.lastCommand, "hello world")
        XCTAssertEqual(
            scanner.lastContext,
            ScanContext(
                channel: .dictatedOneOff,
                destinationBundleID: "com.apple.Terminal",
                manifestID: nil))
        XCTAssertEqual(
            updates.last,
            .confirmBack(
                ConfirmBackInfo(
                    transcript: "hello world",
                    intent: "hello world",
                    skillID: "dictation_insert",
                    riskTier: .alwaysConfirm)))
    }

    func testApproveInsertsStashedText() async {
        let setup = terminalSetup(verdict: .confirm(findings: [confirmFinding()]))
        let inserter = setup.inserter
        let driver = setup.driver

        var updates: [VoiceSessionUpdate] = []
        let confirmed = expectation(description: "confirm-back")
        let executed = expectation(description: "result after approve")
        driver.onUpdate = { update in
            updates.append(update)
            if case .confirmBack = update { confirmed.fulfill() }
            if case .result = update { executed.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [confirmed], timeout: 2)
        XCTAssertTrue(inserter.inserted.isEmpty)

        driver.approve()
        await fulfillment(of: [executed], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        XCTAssertEqual(inserter.inserted.map(\.plan), [.axThenPaste])
        XCTAssertEqual(
            updates.last,
            .result(VoiceSessionResult(transcript: "hello world", summary: "hello world")))
    }

    func testRejectDoesNotInsert() async {
        let setup = terminalSetup(verdict: .confirm(findings: [confirmFinding()]))
        let inserter = setup.inserter
        let driver = setup.driver

        var updates: [VoiceSessionUpdate] = []
        let confirmed = expectation(description: "confirm-back")
        let cancelled = expectation(description: "cancelled result")
        driver.onUpdate = { update in
            updates.append(update)
            if case .confirmBack = update { confirmed.fulfill() }
            if case .result = update { cancelled.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [confirmed], timeout: 2)

        driver.reject()
        await fulfillment(of: [cancelled], timeout: 2)

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(
            updates.last,
            .result(VoiceSessionResult(transcript: "hello world", summary: "Cancelled.")))
    }

    func testHardBlockNeverInserts() async {
        let explanation = "Privilege escalation via sudo is never permitted."
        let setup = terminalSetup(
            verdict: .hardBlock(findings: [hardBlockFinding(explanation: explanation)]))
        let inserter = setup.inserter
        let driver = setup.driver

        var updates: [VoiceSessionUpdate] = []
        let blocked = expectation(description: "hard-blocked")
        driver.onUpdate = { update in
            updates.append(update)
            if case .hardBlocked = update { blocked.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [blocked], timeout: 2)

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(updates.last, .hardBlocked("hello world", explanation))

        driver.approve()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(inserter.inserted.isEmpty, "hard-block has no approve path")
    }

    private func terminalSetup(verdict: ScanVerdict) -> TerminalDictationSetup {
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.apple.Terminal", accessibilityTrusted: true)
        let scanner = RecordingCommandScanner()
        scanner.verdict = verdict
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            scanner: scanner)
        return TerminalDictationSetup(inserter: inserter, scanner: scanner, driver: driver)
    }
}
