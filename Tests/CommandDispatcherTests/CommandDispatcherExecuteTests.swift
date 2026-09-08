import CommandRouter
import SkillManifest
import XCTest

@testable import CommandDispatcher

/// Clean-gate execution, executor failures, and Q&A stub dispatch.
final class CommandDispatcherExecuteTests: XCTestCase {

    private let thresholds = RoutingThresholds(routeHigh: -0.15, routeLow: -0.7)
    private var highLogprob: Float { thresholds.routeHigh + 0.05 }

    func testCleanGateAndCleanScanExecutes() async {
        let scanner = MockCommandScanner()
        let executor = MockBuiltinSkillExecutor()
        executor.result = .success(SkillResult(summary: "Opened Safari"))
        let dispatcher = makeDispatcher(
            manifests: [openApplicationManifest()],
            scanner: scanner,
            executor: executor
        )
        let intent = routedIntent(skillID: "open_application", logprobMean: highLogprob)

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(outcome, .executed(SkillResult(summary: "Opened Safari")))
        XCTAssertEqual(executor.executeCallCount, 1)
        XCTAssertEqual(executor.lastSkillID, "open_application")
        XCTAssertEqual(scanner.scanCallCount, 1)
    }

    func testSkillExecutionThrowFails() async {
        let executor = MockBuiltinSkillExecutor()
        executor.result = .failure(ExecutorBoom())
        let dispatcher = makeDispatcher(
            manifests: [openApplicationManifest()],
            executor: executor
        )
        let intent = routedIntent(skillID: "open_application", logprobMean: highLogprob)

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(outcome, .failed(error: "skill exploded"))
        XCTAssertEqual(executor.executeCallCount, 1)
    }

    func testGeneralQADispatchesStubWithoutScanner() async {
        let scanner = MockCommandScanner()
        scanner.failIfCalled = true
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let dispatcher = makeDispatcher(
            manifests: [generalQAManifest()],
            scanner: scanner,
            executor: executor
        )
        let intent = routedIntent(
            skillID: "general_qa",
            intent: "who wrote Hamlet",
            parameters: .object(["question": .string("who wrote Hamlet")]),
            logprobMean: highLogprob
        )

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(
            outcome,
            .executed(
                SkillResult(
                    summary: "I can't answer general questions yet — that's coming in a future update.")))
        XCTAssertEqual(executor.executeCallCount, 0)
        XCTAssertEqual(scanner.scanCallCount, 0)
    }

    func testScreenQADispatchesStubWithoutScanner() async {
        let scanner = MockCommandScanner()
        scanner.failIfCalled = true
        let executor = MockBuiltinSkillExecutor()
        executor.failIfCalled = true
        let dispatcher = makeDispatcher(
            manifests: [screenQAManifest()],
            scanner: scanner,
            executor: executor
        )
        let intent = routedIntent(
            skillID: "screen_qa",
            intent: "what's on my screen",
            parameters: .object(["question": .string("what's on my screen")]),
            logprobMean: highLogprob
        )

        let outcome = await dispatcher.dispatch(intent, whisperAvgLogprob: -0.2)

        XCTAssertEqual(
            outcome,
            .executed(
                SkillResult(
                    summary:
                        "I can't answer questions about your screen yet — that's coming in a future update.")))
        XCTAssertEqual(executor.executeCallCount, 0)
        XCTAssertEqual(scanner.scanCallCount, 0)
    }
}
