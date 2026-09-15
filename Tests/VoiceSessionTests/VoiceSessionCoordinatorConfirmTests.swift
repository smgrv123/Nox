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

    // MARK: - Confirm-Back safety-net timeout (no auto-hide previously meant an
    // unanswered Confirm-Back left the Overlay on screen and `beginSession`'s
    // `emit(.activate)` guard — legal only from `.hidden`/`.processing` — dead until
    // relaunch; see `VoiceSessionCoordinator.scheduleConfirmBackTimeoutToIdle`).

    func testConfirmBackSchedulesASafetyNetTimeout() {
        let driver = FakeVoiceSessionDriver()
        let overlay = FakeOverlaySink()
        let confirmBackTimeout = FakeScheduler()
        let sut = VoiceSessionCoordinator(
            driver: driver,
            emit: overlay.send,
            playCue: {},
            scheduleAutoHide: { _ in },
            scheduleConfirmBackTimeout: confirmBackTimeout.schedule)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(
            .confirmBack(
                ConfirmBackInfo(
                    transcript: "take a screenshot",
                    intent: "take a screenshot",
                    skillID: "take_screenshot",
                    riskTier: .alwaysConfirm)))

        XCTAssertEqual(
            confirmBackTimeout.scheduled.count, 1,
            "confirm-back schedules exactly one safety-net timeout")
    }

    func testConfirmBackTimeoutFiringDismissesTheOverlayAndUnsticksTheHotkeys() {
        let driver = FakeVoiceSessionDriver()
        let overlay = RealOverlaySink()
        let confirmBackTimeout = FakeScheduler()
        let phase = FakePhaseReporter()
        let sut = VoiceSessionCoordinator(
            driver: driver,
            emit: overlay.send,
            playCue: {},
            scheduleAutoHide: { _ in },
            reportStatus: phase.report,
            scheduleConfirmBackTimeout: confirmBackTimeout.schedule)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(
            .confirmBack(
                ConfirmBackInfo(
                    transcript: "take a screenshot",
                    intent: "take a screenshot",
                    skillID: "take_screenshot",
                    riskTier: .alwaysConfirm)))

        confirmBackTimeout.fireOldest()

        XCTAssertEqual(overlay.state, .hidden, "the timeout dismisses the unanswered Confirm-Back")
        XCTAssertEqual(
            driver.confirmBackTimedOutCallCount, 1,
            "the timeout drops the stashed intent via the driver's confirmBackTimedOut hook")
        XCTAssertEqual(
            driver.rejectCallCount, 0,
            "a timeout must not look like an explicit user Reject to the driver")
        XCTAssertEqual(phase.phases.last, .idle)

        // The actual bug: with the Overlay stuck at .confirmBack, beginSession's
        // emit(.activate) guard fails forever and both hotkeys go dead. Once the
        // timeout has returned the Overlay to .hidden, a fresh PTT press must work.
        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        XCTAssertEqual(overlay.state, .listening, "hotkeys work again after the timeout recovers the Overlay")
        XCTAssertEqual(driver.beginCalls, [.command, .command])
    }

    func testConfirmBackTimeoutFiringAfterAnAlreadyProcessedRejectIsASafeNoOp() {
        let driver = FakeVoiceSessionDriver()
        let overlay = RealOverlaySink()
        let confirmBackTimeout = FakeScheduler()
        let phase = FakePhaseReporter()
        let sut = VoiceSessionCoordinator(
            driver: driver,
            emit: overlay.send,
            playCue: {},
            scheduleAutoHide: { _ in },
            reportStatus: phase.report,
            scheduleConfirmBackTimeout: confirmBackTimeout.schedule)

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

        let rejectCallCountBeforeTimeout = driver.rejectCallCount
        let timedOutCallCountBeforeTimeout = driver.confirmBackTimedOutCallCount
        let phasesBeforeTimeout = phase.phases
        XCTAssertEqual(overlay.state, .hidden, "a real Reject has already returned the Overlay to .hidden")

        confirmBackTimeout.fireOldest()

        XCTAssertEqual(overlay.state, .hidden, "the stale timeout's dismiss is illegal from .hidden and is rejected")
        XCTAssertEqual(
            driver.rejectCallCount, rejectCallCountBeforeTimeout,
            "the state guard must prevent a second driver.reject() from the stale timeout")
        XCTAssertEqual(
            driver.confirmBackTimedOutCallCount, timedOutCallCountBeforeTimeout,
            "the state guard must prevent a stale timeout from firing confirmBackTimedOut after a real Reject")
        XCTAssertEqual(
            phase.phases, phasesBeforeTimeout,
            "the state guard must prevent a duplicate .idle report from the stale timeout")
    }

    func testConfirmBackTimeoutFiringAfterAnAlreadyProcessedApproveIsASafeNoOp() {
        let driver = FakeVoiceSessionDriver()
        let overlay = RealOverlaySink()
        let confirmBackTimeout = FakeScheduler()
        let phase = FakePhaseReporter()
        let sut = VoiceSessionCoordinator(
            driver: driver,
            emit: overlay.send,
            playCue: {},
            scheduleAutoHide: { _ in },
            reportStatus: phase.report,
            scheduleConfirmBackTimeout: confirmBackTimeout.schedule)

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

        let rejectCallCountBeforeTimeout = driver.rejectCallCount
        let timedOutCallCountBeforeTimeout = driver.confirmBackTimedOutCallCount
        XCTAssertEqual(overlay.state, .showingResult, "a real Approve has already moved past Confirm-Back")

        confirmBackTimeout.fireOldest()

        XCTAssertEqual(overlay.state, .showingResult, "the stale timeout's dismiss is illegal from .showingResult")
        XCTAssertEqual(
            driver.rejectCallCount, rejectCallCountBeforeTimeout,
            "the state guard must prevent the stale timeout from rejecting an already-approved session")
        XCTAssertEqual(
            driver.confirmBackTimedOutCallCount, timedOutCallCountBeforeTimeout,
            "the state guard must prevent the stale timeout from firing confirmBackTimedOut on an already-approved session"
        )
    }
}

/// A thin `emit` sink backed by the real `OverlayStateMachine`, used (in place of
/// `FakeOverlaySink`'s hardcoded `accepts = true`) wherever a test needs the actual
/// transition guard — e.g. proving a stale Confirm-Back timeout's `.dismiss` is
/// rejected once a real Approve/Reject has already moved the Overlay on.
private final class RealOverlaySink {
    private var machine = OverlayStateMachine()
    var state: OverlayState { machine.state }
    func send(_ event: OverlayEvent) -> Bool { machine.send(event) }
}
