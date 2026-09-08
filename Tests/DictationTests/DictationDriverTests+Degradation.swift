import AideCore
import SpeechToText
import XCTest

@testable import Dictation

@MainActor
extension DictationDriverTests {

    func testBothPathsFailedCopiesToClipboard() async {
        let capture = FakeCaptureBuffer(finalizeReturns: dictationTestPCM)
        let inserter = RecordingInserter()
        inserter.result = .failed(reason: "Couldn't insert via Accessibility or paste.")
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

        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        XCTAssertEqual(inserter.copied, ["hello world"])
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: "Couldn't insert — copied to clipboard instead.")))
    }

    func testPasteFallbackRecordsOverrideOnce() async {
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.microsoft.VSCode", accessibilityTrusted: true)
        inserter.result = .insertedViaPaste
        let recorded = RecordingOverrideSink()
        var updates: [VoiceSessionUpdate] = []
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            recordOverride: { bundleID, override in
                recorded.record(bundleID: bundleID, override: override)
            })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.plan), [.axThenPaste])
        XCTAssertEqual(recorded.calls.count, 1)
        XCTAssertEqual(recorded.calls.first?.bundleID, "com.microsoft.VSCode")
        XCTAssertEqual(recorded.calls.first?.override, .paste)
        XCTAssertEqual(
            updates.last,
            .result(VoiceSessionResult(transcript: "hello world", summary: "hello world")))
    }

    func testExistingPasteOverrideDoesNotRescanAX() async {
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.microsoft.VSCode", accessibilityTrusted: true)
        inserter.result = .insertedViaPaste
        let recorded = RecordingOverrideSink()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            overrides: { ["com.microsoft.VSCode": .paste] },
            recordOverride: { bundleID, override in
                recorded.record(bundleID: bundleID, override: override)
            })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.plan), [.pasteOnly])
        XCTAssertTrue(recorded.calls.isEmpty, "already-paste override must not be re-learned")
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

        XCTAssertEqual(inserter.inserted.map(\.text), ["hello world"])
        XCTAssertEqual(inserter.inserted.map(\.plan), [.axThenPaste])
        XCTAssertEqual(inserter.copied, [], "successful paste must not copy-escape")
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: "Text insertion needs Accessibility. Enable Aide in System Settings.")))
    }

    func testAccessibilityDeniedRecordsPasteOverride() async {
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.microsoft.VSCode", accessibilityTrusted: false)
        inserter.result = .insertedViaPaste
        let recorded = RecordingOverrideSink()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            recordOverride: { bundleID, override in
                recorded.record(bundleID: bundleID, override: override)
            })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.plan), [.axThenPaste])
        XCTAssertEqual(recorded.calls.count, 1)
        XCTAssertEqual(recorded.calls.first?.bundleID, "com.microsoft.VSCode")
        XCTAssertEqual(recorded.calls.first?.override, .paste)
    }

    func testCopyEscapeWinsOverAccessibilityDeniedMessage() async {
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.apple.TextEdit", accessibilityTrusted: false)
        inserter.result = .failed(reason: "Couldn't insert via Accessibility or paste.")
        var updates: [VoiceSessionUpdate] = []
        let recorded = RecordingOverrideSink()
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            recordOverride: { bundleID, override in
                recorded.record(bundleID: bundleID, override: override)
            })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.copied, ["hello world"])
        XCTAssertTrue(recorded.calls.isEmpty)
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: "Couldn't insert — copied to clipboard instead.")))
    }

    func testPasteOverrideDoesNotShowAccessibilityDeniedMessage() async {
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.microsoft.VSCode", accessibilityTrusted: false)
        inserter.result = .insertedViaPaste
        let recorded = RecordingOverrideSink()
        var updates: [VoiceSessionUpdate] = []
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            overrides: { ["com.microsoft.VSCode": .paste] },
            recordOverride: { bundleID, override in
                recorded.record(bundleID: bundleID, override: override)
            })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { update in
            updates.append(update)
            if case .result = update { resolved.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(inserter.inserted.map(\.plan), [.pasteOnly])
        XCTAssertTrue(recorded.calls.isEmpty)
        XCTAssertEqual(
            updates.last,
            .result(VoiceSessionResult(transcript: "hello world", summary: "hello world")))
    }
}
