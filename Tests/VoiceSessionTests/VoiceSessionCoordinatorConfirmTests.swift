import AideCore
import Hotkeys
import Overlay
import XCTest

@testable import VoiceSession

/// P4 confirm-back / prompt-back / hard-block Overlay mapping, split from
/// `VoiceSessionCoordinatorTests` so SwiftLint `type_body_length` stays honest.
final class VoiceSessionCoordinatorConfirmTests: XCTestCase {

    func testConfirmBackEmitsPresentConfirmBackWithoutAutoHide() {
        let driver = FakeVoiceSessionDriver()
        let overlay = FakeOverlaySink()
        let scheduler = FakeScheduler()
        let sut = makeVoiceSessionCoordinator(driver: driver, overlay: overlay, scheduler: scheduler)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(.transcript("take a screenshot"))
        driver.fire(
            .confirmBack(
                ConfirmBackInfo(
                    transcript: "take a screenshot",
                    intent: "take a screenshot",
                    skillID: "take_screenshot",
                    riskTier: .alwaysConfirm)))

        XCTAssertEqual(
            overlay.events,
            [.activate, .beginProcessing, .presentConfirmBack])
        XCTAssertTrue(scheduler.scheduled.isEmpty, "confirm-back waits for the user")
    }

    func testPromptBackEmitsPresentPromptBackAndAutoHides() {
        let driver = FakeVoiceSessionDriver()
        let overlay = FakeOverlaySink()
        let scheduler = FakeScheduler()
        let sut = makeVoiceSessionCoordinator(driver: driver, overlay: overlay, scheduler: scheduler)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(.promptBack("huh", "Did you mean…?"))
        scheduler.fireOldest()

        XCTAssertEqual(
            overlay.events,
            [.activate, .beginProcessing, .presentPromptBack, .dismiss])
    }

    func testHardBlockedEmitsPresentResultAndAutoHides() {
        let driver = FakeVoiceSessionDriver()
        let overlay = FakeOverlaySink()
        let scheduler = FakeScheduler()
        let sut = makeVoiceSessionCoordinator(driver: driver, overlay: overlay, scheduler: scheduler)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(.hardBlocked("sudo rm", "privilege escalation"))
        scheduler.fireOldest()

        XCTAssertEqual(
            overlay.events,
            [.activate, .beginProcessing, .presentResult, .dismiss])
    }

    func testApproveConfirmBackEmitsApproveThenDriverApprove() {
        let driver = FakeVoiceSessionDriver()
        let overlay = FakeOverlaySink()
        let sut = makeVoiceSessionCoordinator(driver: driver, overlay: overlay)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(
            .confirmBack(
                ConfirmBackInfo(
                    transcript: "open Safari",
                    intent: "open Safari",
                    skillID: "open_application",
                    riskTier: .confirm)))
        sut.approveConfirmBack()

        XCTAssertEqual(driver.approveCallCount, 1)
        XCTAssertTrue(overlay.events.contains(.presentConfirmBack))
        XCTAssertTrue(overlay.events.contains(.approve))
    }

    func testRejectConfirmBackEmitsRejectAndDoesNotApprove() {
        let driver = FakeVoiceSessionDriver()
        let overlay = FakeOverlaySink()
        let sut = makeVoiceSessionCoordinator(driver: driver, overlay: overlay)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(
            .confirmBack(
                ConfirmBackInfo(
                    transcript: "open Safari",
                    intent: "open Safari",
                    skillID: "open_application",
                    riskTier: .confirm)))
        sut.rejectConfirmBack()

        XCTAssertEqual(driver.rejectCallCount, 1)
        XCTAssertEqual(driver.approveCallCount, 0)
        XCTAssertTrue(overlay.events.contains(.reject))
    }
}
