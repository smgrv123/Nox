import AideCore
import SpeechToText
import XCTest

@testable import Dictation

@MainActor
extension DictationDriverTests {

    func testBothPathsFailedCopiesToClipboard() async {
        let capture = FakeCaptureBuffer(finalizeReturns: dictationTestPCM)
        let inserter = RecordingInserter()
        inserter.result = .failed(.pasteFailed(detail: "Couldn't insert via Accessibility or paste."))
        var updates: [VoiceSessionUpdate] = []
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: capture,
            inserter: inserter)

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(inserter.copied, ["hello world"])
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: "Couldn't insert — copied to clipboard instead.")))
    }

    func testSecureInputFailureShowsDistinctSummaryAndCopiesToClipboard() async {
        let capture = FakeCaptureBuffer(finalizeReturns: dictationTestPCM)
        let inserter = RecordingInserter()
        inserter.result = .failed(.secureInput)
        var updates: [VoiceSessionUpdate] = []
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: capture,
            inserter: inserter)

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.copied, ["hello world"])
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: "Couldn't insert — Secure Input is on. Copied to clipboard instead.")))
    }

    func testAccessibilityDeniedShowsFixItAndStillPastes() async {
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.apple.TextEdit", accessibilityTrusted: false)
        inserter.result = .insertedViaPaste
        var updates: [VoiceSessionUpdate] = []
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter)

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(inserter.copied, [], "successful paste must not copy-escape")
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: "Text insertion needs Accessibility. Enable Aide in System Settings.")))
    }

    func testCopyEscapeWinsOverAccessibilityDeniedMessage() async {
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.apple.TextEdit", accessibilityTrusted: false)
        inserter.result = .failed(.pasteFailed(detail: "Couldn't insert via Accessibility or paste."))
        var updates: [VoiceSessionUpdate] = []
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter)

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.copied, ["hello world"])
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: "Couldn't insert — copied to clipboard instead.")))
    }
}
