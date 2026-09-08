import CommandRouter
import DangerousCommandScanner
import SkillManifest
import XCTest

@testable import CommandDispatcher

/// Scanner integration: confirm / hard-block, pre-execution channel, pure skills skip.
final class CommandDispatcherScannerTests: XCTestCase {

    private let thresholds = RoutingThresholds(routeHigh: -0.15, routeLow: -0.7)
    private var highLogprob: Float { thresholds.routeHigh + 0.05 }

    func testCleanGateAndScannerConfirmConfirmsBackWithFindings() async {
        let finding = sampleFinding()
        let scanner = MockCommandScanner()
        scanner.verdict = .confirm(findings: [finding])
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let dispatcher = makeDispatcher(
            manifests: [openApplicationManifest()],
            scanner: scanner,
            executor: executor
        )
        let intent = routedIntent(skillID: "open_application", logprobMean: highLogprob)

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        guard case .confirmBack(let prompt) = outcome else {
            return XCTFail("expected confirmBack, got \(outcome)")
        }
        XCTAssertEqual(prompt.skillID, "open_application")
        XCTAssertEqual(prompt.intent, "open Safari")
        XCTAssertEqual(prompt.findings, [finding])
        XCTAssertEqual(prompt.riskTier, .low)
        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testCleanGateAndScannerHardBlockHardBlocks() async {
        let finding = sampleFinding(
            rule: .privilegeEscalation,
            severity: .hardBlock,
            explanation: "privilege escalation"
        )
        let scanner = MockCommandScanner()
        scanner.verdict = .hardBlock(findings: [finding])
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let dispatcher = makeDispatcher(
            manifests: [openApplicationManifest()],
            scanner: scanner,
            executor: executor
        )
        let intent = routedIntent(skillID: "open_application", logprobMean: highLogprob)

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(outcome, .hardBlocked(reason: "privilege escalation"))
        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testScannerCalledWithPreExecutionForCommandProducingSkills() async {
        let scanner = MockCommandScanner()
        let dispatcher = makeDispatcher(
            manifests: [openApplicationManifest()],
            scanner: scanner
        )
        let intent = routedIntent(skillID: "open_application", logprobMean: highLogprob)

        _ = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(scanner.lastContext, ScanContext(channel: .preExecution))
        XCTAssertEqual(scanner.lastCommand, "open -a \"Safari\"")
    }

    func testScannerNotCalledForCalculate() async {
        let scanner = MockCommandScanner()
        scanner.failIfCalled = true
        let executor = MockBuiltinSkillExecutor()
        executor.result = .success(SkillResult(summary: "42"))
        let dispatcher = makeDispatcher(
            manifests: [calculateManifest()],
            scanner: scanner,
            executor: executor
        )
        let intent = routedIntent(
            skillID: "calculate",
            intent: "what's 6 times 7",
            parameters: .object(["expression": .string("6 * 7")]),
            logprobMean: highLogprob
        )

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(outcome, .executed(SkillResult(summary: "42")))
        XCTAssertEqual(scanner.scanCallCount, 0)
        XCTAssertEqual(executor.lastSkillID, "calculate")
    }

    func testScannerNotCalledForCurrentTime() async {
        let scanner = MockCommandScanner()
        scanner.failIfCalled = true
        let executor = MockBuiltinSkillExecutor()
        executor.result = .success(SkillResult(summary: "12:00"))
        let dispatcher = makeDispatcher(
            manifests: [currentTimeManifest()],
            scanner: scanner,
            executor: executor
        )
        let intent = routedIntent(
            skillID: "current_time",
            intent: "what time is it",
            parameters: .object([:]),
            logprobMean: highLogprob
        )

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(outcome, .executed(SkillResult(summary: "12:00")))
        XCTAssertEqual(scanner.scanCallCount, 0)
    }
}
