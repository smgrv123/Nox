import AideCore
import Hotkeys
import Overlay
import XCTest

@testable import VoiceSession

/// Phase 6's marquee orchestration (`AppCoordinator`'s only consumer). TDD per
/// specs/P1 §"Testing Decisions": every effect is a fake here, so the down→up→
/// result→auto-hide loop, the audio-cue gate, and the PTT-restart-while-processing
/// path are all exercised deterministically — no real delays, no real Overlay.
final class VoiceSessionCoordinatorTests: XCTestCase {

    // MARK: - Happy path: down → up → transcript → result → auto-hide

    func testHappyPathEventSequence() {
        let driver = FakeVoiceSessionDriver()
        let overlay = FakeOverlaySink()
        let scheduler = FakeScheduler()
        let sut = makeVoiceSessionCoordinator(driver: driver, overlay: overlay, scheduler: scheduler)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        XCTAssertEqual(overlay.events, [.activate])
        XCTAssertEqual(driver.beginCalls, [.command])

        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing])
        XCTAssertEqual(driver.endCallCount, 1)

        driver.fire(.transcript(voiceSessionMockTranscript))
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing], "a transcript update is not an Overlay event")
        XCTAssertEqual(sut.transcript, voiceSessionMockTranscript)

        driver.fire(.result(voiceSessionMockResult))
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing, .presentResult])
        XCTAssertEqual(sut.result, voiceSessionMockResult)

        XCTAssertEqual(scheduler.scheduled.count, 1, "a result schedules exactly one auto-hide")
        scheduler.fireOldest()
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing, .presentResult, .dismiss])
    }

    // MARK: - Audio cue

    func testAudioCueFiresOnListenStartWhenEnabled() {
        let cue = FakeCue()
        cue.enabled = true
        let sut = makeVoiceSessionCoordinator(cue: cue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))

        XCTAssertEqual(cue.fireCount, 1)
    }

    func testAudioCueDoesNotFireWhenDisabled() {
        let cue = FakeCue()
        cue.enabled = false
        let sut = makeVoiceSessionCoordinator(cue: cue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))

        XCTAssertEqual(cue.fireCount, 0)
    }

    func testAudioCueDoesNotFireOnPTTUpOrDriverUpdates() {
        let driver = FakeVoiceSessionDriver()
        let cue = FakeCue()
        let sut = makeVoiceSessionCoordinator(driver: driver, cue: cue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(.transcript(voiceSessionMockTranscript))
        driver.fire(.result(voiceSessionMockResult))

        XCTAssertEqual(cue.fireCount, 1, "the cue only fires on the listen-start down-edge")
    }

    // MARK: - Processing-start audio cue (Spec #2: the "audio cue when processing
    // starts" setting was persisted but nothing read it)

    func testProcessingCueFiresOnPTTUpWhenEnabled() {
        let processingCue = FakeCue()
        processingCue.enabled = true
        let sut = makeVoiceSessionCoordinator(processingCue: processingCue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))

        XCTAssertEqual(processingCue.fireCount, 1)
    }

    func testProcessingCueDoesNotFireWhenDisabled() {
        let processingCue = FakeCue()
        processingCue.enabled = false
        let sut = makeVoiceSessionCoordinator(processingCue: processingCue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))

        XCTAssertEqual(processingCue.fireCount, 0)
    }

    func testProcessingCueDoesNotFireOnPTTDownOrDriverUpdates() {
        let driver = FakeVoiceSessionDriver()
        let processingCue = FakeCue()
        let sut = makeVoiceSessionCoordinator(driver: driver, processingCue: processingCue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        driver.fire(.transcript(voiceSessionMockTranscript))
        driver.fire(.result(voiceSessionMockResult))

        XCTAssertEqual(processingCue.fireCount, 0, "the processing cue only fires on the beginProcessing edge")
    }

    // MARK: - Phase reporting (Spec #1: the menubar must reflect Processing/Result,
    // not just the physical hotkey hold)

    func testReportsNothingOnListenStartAppCoordinatorOwnsThatText() {
        let phase = FakePhaseReporter()
        let sut = makeVoiceSessionCoordinator(phase: phase)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))

        XCTAssertTrue(
            phase.phases.isEmpty,
            "listening is already rendered by AppCoordinator.reflectHold off the hotkey .down edge")
    }

    func testReportsProcessingThenResultThenIdleOnAutoHide() {
        let driver = FakeVoiceSessionDriver()
        let scheduler = FakeScheduler()
        let phase = FakePhaseReporter()
        let sut = makeVoiceSessionCoordinator(driver: driver, scheduler: scheduler, phase: phase)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        XCTAssertEqual(phase.phases, [.processing])

        driver.fire(.transcript(voiceSessionMockTranscript))
        XCTAssertEqual(phase.phases, [.processing], "a transcript update is not a phase change")

        driver.fire(.result(voiceSessionMockResult))
        XCTAssertEqual(phase.phases, [.processing, .result(voiceSessionMockResult)])

        XCTAssertEqual(scheduler.scheduled.count, 1)
        scheduler.fireOldest()
        XCTAssertEqual(
            phase.phases, [.processing, .result(voiceSessionMockResult), .idle],
            "auto-hide returns to idle")
    }

    // MARK: - PTT-restart while processing (LLD §10 flow control)

    func testNewPressWhileProcessingCancelsThePriorSessionAndRestarts() {
        let driver = FakeVoiceSessionDriver()
        let overlay = FakeOverlaySink()
        let cue = FakeCue()
        let render = FakeRenderSink()
        let sut = makeVoiceSessionCoordinator(driver: driver, overlay: overlay, cue: cue, render: render)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(.transcript(voiceSessionMockTranscript))

        sut.handle(HotkeyActivation(hotkey: .dictation, phase: .down))

        XCTAssertEqual(driver.cancelCallCount, 1, "the still-in-flight prior session must be cancelled")
        XCTAssertEqual(driver.beginCalls, [.command, .dictation])
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing, .activate], "restart is legal from .processing")
        XCTAssertNil(sut.transcript, "the restart clears the interrupted session's stashed transcript")
        XCTAssertNil(sut.result)
        XCTAssertEqual(cue.fireCount, 2, "the cue fires again on the restart's listen-start")
        XCTAssertNil(render.calls.last?.transcript)
        XCTAssertNil(render.calls.last?.result)

        sut.handle(HotkeyActivation(hotkey: .dictation, phase: .up))
        driver.fire(.result(voiceSessionMockResult))
        XCTAssertEqual(driver.cancelCallCount, 1, "resolving normally must not cancel again")
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing, .activate, .beginProcessing, .presentResult])
    }

    func testFreshPressAfterAutoHideDoesNotCancelAnything() {
        let driver = FakeVoiceSessionDriver()
        let scheduler = FakeScheduler()
        let sut = makeVoiceSessionCoordinator(driver: driver, scheduler: scheduler)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(.result(voiceSessionMockResult))
        scheduler.fireOldest()

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))

        XCTAssertEqual(driver.cancelCallCount, 0)
        XCTAssertEqual(driver.beginCalls, [.command, .command])
    }

    // MARK: - Transcript/result exposed for rendering

    func testTranscriptAndResultAreExposedAsTheySettle() {
        let driver = FakeVoiceSessionDriver()
        let render = FakeRenderSink()
        let sut = makeVoiceSessionCoordinator(driver: driver, render: render)

        XCTAssertNil(sut.transcript)
        XCTAssertNil(sut.result)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))

        driver.fire(.transcript(voiceSessionMockTranscript))
        XCTAssertEqual(sut.transcript, voiceSessionMockTranscript)
        XCTAssertNil(sut.result, "the result has not arrived yet")

        driver.fire(.result(voiceSessionMockResult))
        XCTAssertEqual(sut.transcript, voiceSessionMockTranscript)
        XCTAssertEqual(sut.result, voiceSessionMockResult)

        XCTAssertEqual(
            render.calls.map { $0.transcript },
            [nil, voiceSessionMockTranscript, voiceSessionMockTranscript],
            "reset-on-begin, then transcript, then transcript retained alongside the result")
        XCTAssertEqual(render.calls.map { $0.result }, [nil, nil, voiceSessionMockResult])
    }

    // MARK: - Illegal transitions are respected (defends against a stray edge)

    func testWhenTheOverlayRejectsActivateNoSessionIsStarted() {
        let driver = FakeVoiceSessionDriver()
        let overlay = FakeOverlaySink()
        let cue = FakeCue()
        overlay.accepts = false
        let sut = makeVoiceSessionCoordinator(driver: driver, overlay: overlay, cue: cue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))

        XCTAssertTrue(driver.beginCalls.isEmpty)
        XCTAssertEqual(cue.fireCount, 0)
    }

    func testWhenTheOverlayRejectsBeginProcessingNothingDownstreamFires() {
        let driver = FakeVoiceSessionDriver()
        let overlay = FakeOverlaySink()
        let processingCue = FakeCue()
        let phase = FakePhaseReporter()
        let sut = makeVoiceSessionCoordinator(
            driver: driver, overlay: overlay, processingCue: processingCue, phase: phase)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        overlay.accepts = false
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))

        XCTAssertEqual(driver.endCallCount, 0)
        XCTAssertEqual(processingCue.fireCount, 0, "beginProcessing was rejected — the processing cue must not fire")
        XCTAssertTrue(phase.phases.isEmpty, "beginProcessing was rejected — no processing phase should be reported")
    }
}
