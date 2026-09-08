import AideCore
import SpeechToText
import XCTest

@testable import Dictation

@MainActor
final class DictationDriverTests: XCTestCase {

    func testPassInsertsRawTranscript() async {
        let capture = FakeCaptureBuffer(finalizeReturns: dictationTestPCM)
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: capture,
            inserter: inserter)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        XCTAssertEqual(inserter.inserted.map(\.plan), [.axThenPaste])
        XCTAssertEqual(
            updates,
            [
                .transcript("hello world"),
                .result(
                    VoiceSessionResult(
                        transcript: "hello world",
                        summary: "hello world")),
            ])
    }

    func testPasteOverrideInsertsWithPasteOnly() async {
        let capture = FakeCaptureBuffer(finalizeReturns: dictationTestPCM)
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: capture,
            inserter: inserter,
            overrides: { ["com.apple.TextEdit": .paste] })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.count, 1)
        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        XCTAssertEqual(inserter.inserted.map(\.plan), [.pasteOnly])
    }

    func testInsertFailedStillDeliversTranscriptWithCopyEscapeSummary() async {
        let capture = FakeCaptureBuffer(finalizeReturns: dictationTestPCM)
        let inserter = RecordingInserter()
        let failureReason = "AX insert failed"
        inserter.result = .failed(reason: failureReason)
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: capture,
            inserter: inserter)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        XCTAssertEqual(inserter.inserted.map(\.plan), [.axThenPaste])
        XCTAssertEqual(inserter.copied, ["hello world"])
        XCTAssertEqual(
            updates,
            [
                .transcript("hello world"),
                .result(
                    VoiceSessionResult(
                        transcript: "hello world",
                        summary: DictationDriver.copiedToClipboardSummary)),
            ])
    }

    func testPreGateFailDoesNotInsert() async {
        let capture = FakeCaptureBuffer(finalizeReturns: dictationTestPCM)
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: silentTranscription()),
            capture: capture,
            inserter: inserter)

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testCancelSuppressesInsert() async {
        let capture = FakeCaptureBuffer(finalizeReturns: dictationTestPCM)
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: capture,
            inserter: inserter)

        let noUpdate = expectation(description: "no update after cancel")
        noUpdate.isInverted = true
        driver.onUpdate = { _ in noUpdate.fulfill() }

        driver.begin(mode: .dictation)
        driver.end()
        driver.cancel()

        await fulfillment(of: [noUpdate], timeout: 0.5)
        XCTAssertTrue(inserter.inserted.isEmpty)
        let discards = await capture.discardCount
        XCTAssertGreaterThanOrEqual(discards, 1)
    }

    func testMicrophoneFailureDoesNotInsert() async {
        let capture = FakeCaptureBuffer(finalizeReturns: dictationTestPCM, startFails: true)
        let inserter = RecordingInserter()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: capture,
            inserter: inserter)

        var updates: [VoiceSessionUpdate] = []
        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(
            updates,
            [
                .result(
                    VoiceSessionResult(transcript: "", summary: DictationDriver.microphoneUnavailableSummary))
            ])
    }
}
