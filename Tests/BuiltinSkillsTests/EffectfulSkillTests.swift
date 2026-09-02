import SkillManifest
import XCTest

@testable import BuiltinSkills

final class EffectfulSkillTests: XCTestCase {

    func testOpenApplicationCallsProtocolWithAppName() async throws {
        let system = MockSystemSkillExecutor()
        _ = try await makeRouter(system: system).execute(
            skillID: "open_application",
            parameters: objectParams(["app_name": .string("Safari")])
        )
        XCTAssertEqual(system.openCalls, ["Safari"])
    }

    func testQuitApplicationCallsProtocolWithAppName() async throws {
        let system = MockSystemSkillExecutor()
        _ = try await makeRouter(system: system).execute(
            skillID: "quit_application",
            parameters: objectParams(["app_name": .string("Xcode")])
        )
        XCTAssertEqual(system.quitCalls, ["Xcode"])
    }

    func testSetTimerCallsProtocolWithDurationAndLabel() async throws {
        let system = MockSystemSkillExecutor()
        _ = try await makeRouter(system: system).execute(
            skillID: "set_timer",
            parameters: objectParams([
                "duration_seconds": .int(300),
                "label": .string("pasta"),
            ])
        )
        XCTAssertEqual(system.timerCalls.count, 1)
        XCTAssertEqual(system.timerCalls.first?.durationSeconds, 300)
        XCTAssertEqual(system.timerCalls.first?.label, "pasta")
    }

    func testMediaControlCallsProtocolWithAction() async throws {
        for action in ["play", "pause", "next", "previous"] {
            let system = MockSystemSkillExecutor()
            _ = try await makeRouter(system: system).execute(
                skillID: "media_control",
                parameters: objectParams(["action": .string(action)])
            )
            XCTAssertEqual(system.mediaCalls, [action], "action \(action)")
        }
    }

    func testTakeScreenshotReportsSavedPathInSummary() async throws {
        let system = MockSystemSkillExecutor()
        system.screenshotPath = "/tmp/aide-screenshot.png"
        let result = try await makeRouter(system: system).execute(
            skillID: "take_screenshot",
            parameters: objectParams(["region": .string("selection")])
        )
        XCTAssertEqual(system.screenshotCalls, ["selection"])
        XCTAssertTrue(
            result.summary.contains("/tmp/aide-screenshot.png"),
            "summary must report the saved path, got \(result.summary)"
        )
    }

    func testTakeScreenshotCallsProtocolWithRegion() async throws {
        for region in ["selection", "window"] {
            let system = MockSystemSkillExecutor()
            _ = try await makeRouter(system: system).execute(
                skillID: "take_screenshot",
                parameters: objectParams(["region": .string(region)])
            )
            XCTAssertEqual(system.screenshotCalls, [region], "region \(region)")
        }
    }

    func testTakeScreenshotMapsFullScreenAliasToFull() async throws {
        let system = MockSystemSkillExecutor()
        _ = try await makeRouter(system: system).execute(
            skillID: "take_screenshot",
            parameters: objectParams(["region": .string("full_screen")])
        )
        XCTAssertEqual(system.screenshotCalls, ["full"])
    }
}
