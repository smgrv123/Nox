import AideCore
import DangerousCommandScanner
import LLMRuntime
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
        XCTAssertEqual(inserter.inserted, ["hello world"])
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

        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(
                    transcript: "hello world",
                    summary: "hello world")))
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

    func testTerminalScanRunsOnRawTextNotCleaned() async {
        // Terminal destinations must skip cleanup entirely (dictated shell commands
        // stay verbatim — the tone prompt's mandated capitalisation/terminal
        // punctuation would otherwise corrupt `git status` into `Git status.`). Even
        // with an LLM wired up and ready to clean, the scanner and the insert must
        // both see the raw transcript, and the LLM must never be called.
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "cleaned command", isFinal: true)]))
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.apple.Terminal", accessibilityTrusted: true)
        let scanner = RecordingCommandScanner()
        scanner.verdict = .confirm(findings: [confirmFinding()])
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            scanner: scanner,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() })

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

        XCTAssertEqual(
            scanner.lastCommand, "hello world",
            "terminal destinations skip cleanup — the scanner must see the raw transcript")
        XCTAssertEqual(
            updates.last,
            .confirmBack(
                ConfirmBackInfo(
                    transcript: "hello world",
                    intent: "hello world",
                    skillID: "dictation_insert",
                    riskTier: .alwaysConfirm)))

        driver.approve()
        await fulfillment(of: [executed], timeout: 2)

        XCTAssertEqual(
            inserter.inserted, ["hello world"],
            "approve() must insert the same raw text shown in Confirm-Back")
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(
            chatCount, 1,
            "terminal destinations must skip real LLM cleanup entirely — the one call here is"
                + " prefill, fired at key-down before the destination bundle is known")
        let params = await llm.lastSamplingParams
        XCTAssertEqual(
            params?.maxTokens, 1,
            "the single chat call must be prefill (maxTokens: 1), not a stray real cleanup call"
                + " (maxTokens: 1024)")
    }

    func testHardBlockSkipsCleanupButNeverInserts() async {
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "cleaned command", isFinal: true)]))
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.apple.Terminal", accessibilityTrusted: true)
        let scanner = RecordingCommandScanner()
        scanner.verdict = .hardBlock(findings: [hardBlockFinding()])
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            scanner: scanner,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() })

        let blocked = expectation(description: "hard-blocked")
        driver.onUpdate = { update in
            if case .hardBlocked = update { blocked.fulfill() }
        }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [blocked], timeout: 2)

        XCTAssertTrue(inserter.inserted.isEmpty, "hard-block never inserts")
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(
            chatCount, 1,
            "terminal destinations skip real cleanup entirely, even for text that ends up"
                + " hard-blocked — the one call here is prefill, fired at key-down before the"
                + " destination bundle is known")
        let params = await llm.lastSamplingParams
        XCTAssertEqual(
            params?.maxTokens, 1,
            "the single chat call must be prefill (maxTokens: 1), not a stray real cleanup call"
                + " (maxTokens: 1024)")
    }

    func testNonTerminalDestinationStillGetsCleaned() async {
        // Guard against the terminal-skip fix silently disabling cleanup everywhere:
        // a non-terminal destination must still route through the LLM.
        let llm = MockLLMClient()
        await llm.setChatChunks(.success([ChatCompletionChunk(delta: "Cleaned.", isFinal: true)]))
        let inserter = RecordingInserter()
        inserter.focus = InsertionFocus(bundleID: "com.apple.TextEdit", accessibilityTrusted: true)
        let driver = makeDictationDriver(
            engine: MockSTTEngine(returning: passingTranscription()),
            capture: FakeCaptureBuffer(finalizeReturns: dictationTestPCM),
            inserter: inserter,
            llm: llm,
            resolveEndpoint: { dictationTestEndpoint() })

        let resolved = expectation(description: "result delivered")
        driver.onUpdate = { if case .result = $0 { resolved.fulfill() } }

        driver.begin(mode: .dictation)
        driver.end()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(
            inserter.inserted, ["Cleaned."], "non-terminal destinations must still be cleaned")
        let chatCount = await llm.chatCallCount
        XCTAssertEqual(
            chatCount, 2,
            "the terminal-skip fix must not disable cleanup for non-terminal destinations — one"
                + " prefill call at begin(mode:) plus one real cleanup call at Pre-Gate pass")
    }

    func terminalSetup(verdict: ScanVerdict) -> TerminalDictationSetup {
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
