import SkillManifest
import XCTest

@testable import CommandDispatcher

/// Pins which built-ins produce a scan-able command vs pure compute / Q&A stubs.
final class ExecutableCommandRendererTests: XCTestCase {

    func testOpenApplicationRendersOpenDashA() {
        let command = ExecutableCommandRenderer.render(
            skillID: "open_application",
            parameters: .object(["app_name": .string("Safari")])
        )
        XCTAssertEqual(command, "open -a \"Safari\"")
    }

    func testQuitApplicationRendersOsascriptQuit() {
        let command = ExecutableCommandRenderer.render(
            skillID: "quit_application",
            parameters: .object(["app_name": .string("Xcode")])
        )
        XCTAssertEqual(command, "osascript -e 'quit app \"Xcode\"'")
    }

    func testSetTimerRendersSleep() {
        let command = ExecutableCommandRenderer.render(
            skillID: "set_timer",
            parameters: .object(["duration_seconds": .int(30)])
        )
        XCTAssertEqual(command, "sleep 30")
    }

    func testMediaControlRendersMusicOsascript() {
        let command = ExecutableCommandRenderer.render(
            skillID: "media_control",
            parameters: .object(["action": .string("pause")])
        )
        XCTAssertEqual(command, "osascript -e 'tell application \"Music\" to pause'")
    }

    func testTakeScreenshotRendersScreencapture() {
        let command = ExecutableCommandRenderer.render(
            skillID: "take_screenshot",
            parameters: .object([:])
        )
        XCTAssertEqual(command, "screencapture -x ~/Desktop/aide-screenshot.png")
    }

    func testPureSkillsRenderNil() {
        for skillID in ExecutableCommandRenderer.pureSkillIDs {
            XCTAssertNil(
                ExecutableCommandRenderer.render(skillID: skillID, parameters: .object([:])),
                "\(skillID) must not produce a command"
            )
            XCTAssertFalse(ExecutableCommandRenderer.isExecutable(skillID))
        }
    }

    func testExecutableSkillIDsAreMarkedExecutable() {
        for skillID in ExecutableCommandRenderer.executableSkillIDs {
            XCTAssertTrue(ExecutableCommandRenderer.isExecutable(skillID))
            XCTAssertNotNil(
                ExecutableCommandRenderer.render(skillID: skillID, parameters: .object([:])),
                "\(skillID) must produce a command string"
            )
        }
    }
}
