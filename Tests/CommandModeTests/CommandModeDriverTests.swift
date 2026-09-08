import AideCore
import CommandDispatcher
import CommandRouter
import DangerousCommandScanner
import Foundation
import LLMRuntime
import SkillManifest
import SkillRegistry
import SpeechToText
import XCTest

@testable import CommandMode

private struct ExecutorBoom: LocalizedError {
    var errorDescription: String? { "skill exploded" }
}

/// End-to-end Command Mode pipeline: capture → STT → Pre-Gate → Route → Dispatch → Overlay.
/// Headless on the main actor (STTVoiceSessionDriverTests idiom).
@MainActor
final class CommandModeDriverTests: XCTestCase {

    func testOpenSafariDeliversTranscriptThenSuccessSummary() async throws {
        let executor = MockBuiltinSkillExecutor()
        executor.result = .success(SkillResult(summary: "Opened Safari"))
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            executor: executor
        )

        let updates = await collectResult(from: driver)

        XCTAssertEqual(
            updates,
            [
                .transcript("open Safari"),
                .result(VoiceSessionResult(transcript: "open Safari", summary: "Opened Safari")),
            ],
            "passing Pre-Gate + clean route + execute delivers the skill summary")
        XCTAssertEqual(executor.executeCallCount, 1)
    }

    func testNullSkillDeliversPromptBackSummary() async throws {
        let raw = #"{"intent":"nothing matches","skill_id":null,"parameters":{}}"#
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let driver = try await makeDriver(
            route: RouteStub(raw: raw, skillLiteral: "null", logprob: -0.08),
            executor: executor
        )

        let updates = await collectResult(from: driver)

        XCTAssertEqual(
            updates,
            [
                .transcript("open Safari"),
                .promptBack("open Safari", ConfidenceGate.promptBackSuggestion),
            ],
            "skill_id null is prompt-back, never guess-execute")
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testConfirmTierMarginalConfidenceDeliversConfirmBackSummary() async throws {
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -2.5),
            manifests: [openApplicationManifest(riskTier: .confirm)],
            executor: executor
        )

        let updates = await collectResult(from: driver)

        XCTAssertEqual(
            updates,
            [
                .transcript("open Safari"),
                .confirmBack(
                    ConfirmBackInfo(
                        transcript: "open Safari",
                        intent: "open Safari",
                        skillID: "open_application",
                        riskTier: .confirm)),
            ],
            "confirm-tier + marginal routing mean is Confirm-Back, not auto-execute")
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testScannerHardBlockDeliversBlockedSummary() async throws {
        let scanner = MockCommandScanner()
        scanner.verdict = .hardBlock(
            findings: [
                Finding(
                    rule: .privilegeEscalation,
                    severity: .hardBlock,
                    matchedText: "sudo",
                    explanation: "privilege escalation")
            ])
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            scanner: scanner,
            executor: executor
        )

        let updates = await collectResult(from: driver)

        XCTAssertEqual(
            updates,
            [
                .transcript("open Safari"),
                .hardBlocked("open Safari", "privilege escalation"),
            ],
            "scanner Hard-Block surfaces the finding reason, never executes")
        XCTAssertEqual(executor.executeCallCount, 0)
        XCTAssertEqual(scanner.scanCallCount, 1)
    }

    func testApproveRedispatchesStashedIntent() async throws {
        let executor = MockBuiltinSkillExecutor()
        executor.result = .success(SkillResult(summary: "Opened Safari"))
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -2.5),
            manifests: [openApplicationManifest(riskTier: .confirm)],
            executor: executor
        )

        var updates: [VoiceSessionUpdate] = []
        let confirmed = expectation(description: "confirm-back")
        let executed = expectation(description: "executed after approve")
        driver.onUpdate = { update in
            updates.append(update)
            if case .confirmBack = update { confirmed.fulfill() }
            if case .result = update { executed.fulfill() }
        }
        driver.begin(mode: .command)
        driver.end()
        await fulfillment(of: [confirmed], timeout: 2)
        XCTAssertEqual(executor.executeCallCount, 0)

        driver.approve()
        await fulfillment(of: [executed], timeout: 2)
        XCTAssertEqual(executor.executeCallCount, 1)
        XCTAssertEqual(
            updates.last,
            .result(VoiceSessionResult(transcript: "open Safari", summary: "Opened Safari")))
    }

    func testInstalledAppNamesBiasSTTInitialPrompt() async throws {
        let executor = MockBuiltinSkillExecutor()
        executor.result = .success(SkillResult(summary: "Opened Safari"))
        let recordingEngine = RecordingSTTEngine(returning: passingTranscription(text: "open Safari"))
        let appCatalog = FakeInstalledApplicationCatalog(apps: [
            InstalledApplication(
                displayName: "Ghostty", bundleURL: URL(fileURLWithPath: "/Applications/Ghostty.app")),
            InstalledApplication(
                displayName: "Safari", bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")),
        ])
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            executor: executor,
            engine: recordingEngine,
            appCatalog: appCatalog
        )

        _ = await collectResult(from: driver)

        let initialPrompt = await recordingEngine.lastInitialPrompt
        let prompt = try XCTUnwrap(initialPrompt, "transcribe should receive a non-nil initialPrompt")
        XCTAssertTrue(prompt.contains("Ghostty"))
        XCTAssertTrue(prompt.contains("Safari"))
    }

    func testRejectDoesNotExecute() async throws {
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let logURL = try temporaryLogURL()
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -2.5),
            manifests: [openApplicationManifest(riskTier: .confirm)],
            executor: executor,
            logFileURL: logURL
        )

        _ = await collectResult(from: driver)
        driver.reject()
        let json = try await waitForLog(at: logURL)
        XCTAssertEqual(executor.executeCallCount, 0)
        XCTAssertEqual(json["user_outcome"] as? String, "rejected")
        XCTAssertEqual(json["action_taken"] as? String, "confirm_back")
    }
}

/// Calibration JSONL: one line per Command Mode `.result`, including non-dispatch failures.
@MainActor
final class CommandModeDriverCalibrationTests: XCTestCase {

    func testSuccessfulDispatchAppendsCalibrationRecord() async throws {
        let logURL = try temporaryLogURL()
        let executor = MockBuiltinSkillExecutor()
        executor.result = .success(SkillResult(summary: "Opened Safari"))
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            executor: executor,
            logFileURL: logURL
        )

        _ = await collectResult(from: driver)

        let json = try await waitForLog(at: logURL)
        XCTAssertEqual(json["chosen_skill_id"] as? String, "open_application")
        XCTAssertEqual(json["action_taken"] as? String, "executed")
        XCTAssertEqual(json["scanner_verdict"] as? String, "clean")
        XCTAssertEqual(json["risk_tier"] as? String, "low")
        XCTAssertEqual(json["stt_pregate"] as? String, "pass")
        XCTAssertTrue(json["user_outcome"] is NSNull)
        let whisper = try XCTUnwrap(json["whisper_avg_logprob"] as? Double)
        let routing = try XCTUnwrap(json["routing_logprob_mean"] as? Double)
        XCTAssertEqual(whisper, -0.30, accuracy: 0.0001)
        XCTAssertEqual(routing, -0.08, accuracy: 0.0001)
    }

    func testScannerHardBlockLogsHardBlockActionTaken() async throws {
        let logURL = try temporaryLogURL()
        let scanner = MockCommandScanner()
        scanner.verdict = .hardBlock(
            findings: [
                Finding(
                    rule: .privilegeEscalation,
                    severity: .hardBlock,
                    matchedText: "sudo",
                    explanation: "privilege escalation")
            ])
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            scanner: scanner,
            executor: executor,
            logFileURL: logURL
        )

        _ = await collectResult(from: driver)

        let json = try await waitForLog(at: logURL)
        XCTAssertEqual(json["action_taken"] as? String, "hard_block")
        XCTAssertEqual(json["scanner_verdict"] as? String, "hard_block")
        XCTAssertTrue(json["user_outcome"] is NSNull)
    }

    func testExecutorThrowLogsPromptedBackActionTaken() async throws {
        let logURL = try temporaryLogURL()
        let executor = MockBuiltinSkillExecutor()
        executor.result = .failure(ExecutorBoom())
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            executor: executor,
            logFileURL: logURL
        )

        _ = await collectResult(from: driver)

        let json = try await waitForLog(at: logURL)
        XCTAssertEqual(json["action_taken"] as? String, "prompted_back")
        XCTAssertTrue(json["user_outcome"] is NSNull)
    }

    func testPreGateFailLogsPromptedBackCalibrationRecord() async throws {
        let logURL = try temporaryLogURL()
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            executor: executor,
            logFileURL: logURL,
            engine: MockSTTEngine(returning: silentTranscription())
        )

        let updates = await collectResult(from: driver)

        XCTAssertEqual(
            updates,
            [.result(VoiceSessionResult(transcript: "", summary: CommandModeDriver.reAskSummary))],
            "silent capture is a Pre-Gate fail — re-ask, no transcript first")
        let json = try await waitForLog(at: logURL)
        XCTAssertEqual(json["stt_pregate"] as? String, "fail")
        XCTAssertEqual(json["action_taken"] as? String, "prompted_back")
        XCTAssertTrue(json["chosen_skill_id"] is NSNull)
        XCTAssertTrue(json["routing_logprob_mean"] is NSNull)
        XCTAssertTrue(json["scanner_verdict"] is NSNull)
        XCTAssertTrue(json["risk_tier"] is NSNull)
        XCTAssertTrue(json["user_outcome"] is NSNull)
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testMicUnavailableLogsPromptedBackCalibrationRecord() async throws {
        let logURL = try temporaryLogURL()
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            executor: executor,
            logFileURL: logURL,
            capture: FakeCaptureBuffer(finalizeReturns: commandModePCM, startFails: true)
        )

        let updates = await collectResult(from: driver)

        XCTAssertEqual(
            updates,
            [
                .result(
                    VoiceSessionResult(
                        transcript: "", summary: CommandModeDriver.microphoneUnavailableSummary))
            ])
        let json = try await waitForLog(at: logURL)
        XCTAssertEqual(json["stt_pregate"] as? String, "fail")
        XCTAssertEqual(json["action_taken"] as? String, "prompted_back")
        XCTAssertTrue(json["whisper_avg_logprob"] is NSNull)
        XCTAssertTrue(json["chosen_skill_id"] is NSNull)
        XCTAssertTrue(json["scanner_verdict"] is NSNull)
        XCTAssertTrue(json["risk_tier"] is NSNull)
        XCTAssertTrue(json["user_outcome"] is NSNull)
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testModelNotReadyLogsPromptedBackCalibrationRecord() async throws {
        let logURL = try temporaryLogURL()
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            executor: executor,
            logFileURL: logURL,
            engine: ThrowingSTTEngine()
        )

        let updates = await collectResult(from: driver)

        XCTAssertEqual(
            updates,
            [
                .result(
                    VoiceSessionResult(
                        transcript: "", summary: CommandModeDriver.modelNotReadySummary))
            ])
        let json = try await waitForLog(at: logURL)
        XCTAssertEqual(json["stt_pregate"] as? String, "fail")
        XCTAssertEqual(json["action_taken"] as? String, "prompted_back")
        XCTAssertTrue(json["whisper_avg_logprob"] is NSNull)
        XCTAssertTrue(json["chosen_skill_id"] is NSNull)
        XCTAssertTrue(json["scanner_verdict"] is NSNull)
        XCTAssertTrue(json["risk_tier"] is NSNull)
        XCTAssertTrue(json["user_outcome"] is NSNull)
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testRoutingFailureLogsPromptedBackCalibrationRecord() async throws {
        let logURL = try temporaryLogURL()
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            executor: executor,
            logFileURL: logURL,
            router: ThrowingRouter()
        )

        let updates = await collectResult(from: driver)

        XCTAssertEqual(updates.first, .transcript("open Safari"))
        XCTAssertEqual(
            updates.last,
            .result(
                VoiceSessionResult(transcript: "open Safari", summary: "router down")),
            "a router throw still delivers .result so Overlay can surface it")
        let json = try await waitForLog(at: logURL)
        XCTAssertEqual(json["stt_pregate"] as? String, "pass")
        XCTAssertEqual(json["action_taken"] as? String, "prompted_back")
        XCTAssertTrue(json["chosen_skill_id"] is NSNull)
        XCTAssertTrue(json["id_selecting_token_count"] is NSNull)
        XCTAssertTrue(json["routing_logprob_sum"] is NSNull)
        XCTAssertTrue(json["routing_logprob_mean"] is NSNull)
        XCTAssertTrue(json["param_validation"] is NSNull)
        XCTAssertTrue(json["scanner_verdict"] is NSNull)
        XCTAssertTrue(json["risk_tier"] is NSNull)
        XCTAssertTrue(json["user_outcome"] is NSNull)
        let whisper = try XCTUnwrap(json["whisper_avg_logprob"] as? Double)
        XCTAssertEqual(whisper, -0.30, accuracy: 0.0001)
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testPromptBackLogsDismissedUserOutcome() async throws {
        let logURL = try temporaryLogURL()
        let raw = #"{"intent":"nothing matches","skill_id":null,"parameters":{}}"#
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let driver = try await makeDriver(
            route: RouteStub(raw: raw, skillLiteral: "null", logprob: -0.08),
            executor: executor,
            logFileURL: logURL
        )

        _ = await collectResult(from: driver)
        let json = try await waitForLog(at: logURL)
        XCTAssertEqual(json["action_taken"] as? String, "prompted_back")
        XCTAssertEqual(json["user_outcome"] as? String, "dismissed")
    }

    func testApproveLogsAcceptedUserOutcome() async throws {
        let logURL = try temporaryLogURL()
        let executor = MockBuiltinSkillExecutor()
        executor.result = .success(SkillResult(summary: "Opened Safari"))
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -2.5),
            manifests: [openApplicationManifest(riskTier: .confirm)],
            executor: executor,
            logFileURL: logURL
        )

        let confirmed = expectation(description: "confirm-back")
        driver.onUpdate = { update in
            if case .confirmBack = update { confirmed.fulfill() }
        }
        driver.begin(mode: .command)
        driver.end()
        await fulfillment(of: [confirmed], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))

        let executed = expectation(description: "executed")
        driver.onUpdate = { update in
            if case .result = update { executed.fulfill() }
        }
        driver.approve()
        await fulfillment(of: [executed], timeout: 2)
        let json = try await waitForLog(at: logURL)
        XCTAssertEqual(json["user_outcome"] as? String, "accepted")
        XCTAssertEqual(json["action_taken"] as? String, "executed")
    }
}
