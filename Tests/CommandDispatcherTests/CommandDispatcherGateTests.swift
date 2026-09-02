import CommandRouter
import DangerousCommandScanner
import SkillManifest
import XCTest

@testable import CommandDispatcher

/// Confidence gate outcomes, unknown/nil skill, and scanner/gate precedence.
final class CommandDispatcherGateTests: XCTestCase {

    private let thresholds = RoutingThresholds(routeHigh: -0.15, routeLow: -0.7)
    private var highLogprob: Float { thresholds.routeHigh + 0.05 }
    private var lowLogprob: Float { thresholds.routeLow - 0.05 }
    private var marginalLogprob: Float { (thresholds.routeLow + thresholds.routeHigh) / 2 }

    func testGatePromptBackStillScansExecutable() async {
        let scanner = MockCommandScanner()
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let dispatcher = makeDispatcher(
            manifests: [openApplicationManifest()],
            scanner: scanner,
            executor: executor
        )
        let intent = routedIntent(skillID: "open_application", logprobMean: lowLogprob)

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(
            outcome, .promptedBack(suggestion: ConfidenceGate.promptBackSuggestion))
        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testWeakConfidenceExecutableHardBlockBeatsPromptBack() async {
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
        let intent = routedIntent(skillID: "open_application", logprobMean: lowLogprob)

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(outcome, .hardBlocked(reason: "privilege escalation"))
        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testGateConfirmBackStillCallsScannerWithNilFindings() async {
        let scanner = MockCommandScanner()
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let dispatcher = makeDispatcher(
            manifests: [openApplicationManifest(riskTier: .alwaysConfirm)],
            scanner: scanner,
            executor: executor
        )
        let intent = routedIntent(skillID: "open_application", logprobMean: highLogprob)

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        guard case .confirmBack(let prompt) = outcome else {
            return XCTFail("expected confirmBack, got \(outcome)")
        }
        XCTAssertNil(prompt.findings)
        XCTAssertEqual(prompt.riskTier, .alwaysConfirm)
        XCTAssertEqual(scanner.scanCallCount, 1)
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testGateConfirmBackMergesScannerFindings() async {
        let finding = sampleFinding(explanation: "piped remote execution")
        let scanner = MockCommandScanner()
        scanner.verdict = .confirm(findings: [finding])
        let dispatcher = makeDispatcher(
            manifests: [openApplicationManifest(riskTier: .confirm)],
            scanner: scanner
        )
        let intent = routedIntent(skillID: "open_application", logprobMean: marginalLogprob)

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        guard case .confirmBack(let prompt) = outcome else {
            return XCTFail("expected confirmBack, got \(outcome)")
        }
        XCTAssertEqual(prompt.findings, [finding])
        XCTAssertEqual(scanner.scanCallCount, 1)
    }

    func testNilSkillPromptsBackWithoutRegistryOrScanner() async {
        let scanner = MockCommandScanner()
        scanner.failIfCalled = true
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let registry = SpySkillRegistry(manifests: [openApplicationManifest()])
        let dispatcher = CommandDispatcher(
            registry: registry,
            scanner: scanner,
            executor: executor,
            thresholds: thresholds
        )
        let intent = routedIntent(skillID: nil, logprobMean: highLogprob)

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(
            outcome, .promptedBack(suggestion: ConfidenceGate.promptBackSuggestion))
        let validateCount = await registry.validateCallCount
        let manifestCount = await registry.manifestCallCount
        XCTAssertEqual(validateCount, 0)
        XCTAssertEqual(manifestCount, 0)
        XCTAssertEqual(scanner.scanCallCount, 0)
    }

    func testUnknownSkillFails() async {
        let scanner = MockCommandScanner()
        scanner.failIfCalled = true
        let dispatcher = makeDispatcher(
            manifests: [openApplicationManifest()],
            scanner: scanner
        )
        let intent = routedIntent(skillID: "not_a_skill", logprobMean: highLogprob)

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(outcome, .failed(error: "unknown skill: not_a_skill"))
        XCTAssertEqual(scanner.scanCallCount, 0)
    }

    func testInvalidParametersPromptBackWithoutScanner() async {
        let scanner = MockCommandScanner()
        scanner.failIfCalled = true
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let dispatcher = makeDispatcher(
            manifests: [openApplicationManifest()],
            scanner: scanner,
            executor: executor
        )
        let intent = routedIntent(
            skillID: "open_application",
            parameters: .object([:]),
            logprobMean: highLogprob
        )

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(
            outcome, .promptedBack(suggestion: ConfidenceGate.promptBackSuggestion))
        XCTAssertEqual(scanner.scanCallCount, 0)
        XCTAssertEqual(executor.executeCallCount, 0)
    }

    func testScannerHardBlockWinsOverGateConfirmBack() async {
        let finding = sampleFinding(
            rule: .privilegeEscalation,
            severity: .hardBlock,
            explanation: "privilege escalation"
        )
        let scanner = MockCommandScanner()
        scanner.verdict = .hardBlock(findings: [finding])
        let dispatcher = makeDispatcher(
            manifests: [openApplicationManifest(riskTier: .alwaysConfirm)],
            scanner: scanner
        )
        let intent = routedIntent(skillID: "open_application", logprobMean: highLogprob)

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(outcome, .hardBlocked(reason: "privilege escalation"))
        XCTAssertEqual(scanner.scanCallCount, 1)
    }
}
