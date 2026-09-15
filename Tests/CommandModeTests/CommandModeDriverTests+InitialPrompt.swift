import AideCore
import CommandDispatcher
import SpeechToText
import XCTest

@testable import CommandMode

@MainActor
extension CommandModeDriverTests {

    func testInstalledAppNamesBiasSTTInitialPrompt() async throws {
        let executor = MockBuiltinSkillExecutor()
        executor.result = .success(SkillResult(summary: "Opened Safari"))
        let engine = MockSTTEngine(returning: passingTranscription(text: "open Safari"))
        let appCatalog = FakeInstalledApplicationCatalog(apps: [
            InstalledApplication(
                displayName: "Ghostty", bundleURL: URL(fileURLWithPath: "/Applications/Ghostty.app")),
            InstalledApplication(
                displayName: "Safari", bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")),
        ])
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            executor: executor,
            engine: engine,
            appCatalog: appCatalog
        )

        _ = await collectResult(from: driver)

        let initialPrompt = await engine.lastInitialPrompt
        let prompt = try XCTUnwrap(initialPrompt, "transcribe should receive a non-nil initialPrompt")
        XCTAssertTrue(prompt.contains("Ghostty"))
        XCTAssertTrue(prompt.contains("Safari"))
    }

    func testInjectedInitialPromptIsPassedToSTT() async throws {
        let executor = MockBuiltinSkillExecutor()
        executor.result = .success(SkillResult(summary: "Opened Safari"))
        let engine = MockSTTEngine(returning: passingTranscription(text: "open Safari"))
        let driver = try await makeDriver(
            route: openSafariRoute(logprob: -0.08),
            executor: executor,
            engine: engine,
            makeInitialPrompt: { "Kubernetes, Ghostty" }
        )

        _ = await collectResult(from: driver)

        let prompt = await engine.lastInitialPrompt
        XCTAssertEqual(prompt, "Kubernetes, Ghostty")
    }
}
