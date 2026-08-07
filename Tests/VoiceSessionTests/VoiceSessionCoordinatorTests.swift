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

    // MARK: - Test doubles

    /// A scriptable `VoiceSessionDriver`: `begin`/`end`/`cancel` are recorded, and
    /// `onUpdate` only fires when a test calls `fire(_:)` — so a test controls exactly
    /// when "the mock inference" resolves.
    private final class FakeDriver: VoiceSessionDriver {
        var onUpdate: ((VoiceSessionUpdate) -> Void)?
        private(set) var beginCalls: [VoiceSessionMode] = []
        private(set) var endCallCount = 0
        private(set) var cancelCallCount = 0

        func begin(mode: VoiceSessionMode) { beginCalls.append(mode) }
        func end() { endCallCount += 1 }
        func cancel() { cancelCallCount += 1 }
        func fire(_ update: VoiceSessionUpdate) { onUpdate?(update) }
    }

    /// Stands in for `OverlayController.send`: records every event handed to it and
    /// answers `accepts` (set `false` to simulate the real state machine rejecting an
    /// illegal transition; `true` — accept everything — otherwise).
    private final class FakeOverlaySink {
        private(set) var events: [OverlayEvent] = []
        var accepts = true
        func send(_ event: OverlayEvent) -> Bool {
            events.append(event)
            return accepts
        }
    }

    /// Captures scheduled auto-hide work instead of running it — the "fake clock":
    /// a test calls `fireOldest()` to simulate the delay elapsing.
    private final class FakeScheduler {
        private(set) var scheduled: [() -> Void] = []
        func schedule(_ work: @escaping () -> Void) { scheduled.append(work) }
        func fireOldest() {
            guard !scheduled.isEmpty else { return }
            scheduled.removeFirst()()
        }
    }

    /// Counts `playCue` invocations; `enabled` mirrors the App layer's
    /// `settings.indicators.audioCueOnListen` gate, which the coordinator itself has
    /// no visibility into — proving the seam works whichever way the caller wires it.
    private final class FakeCue {
        private(set) var fireCount = 0
        var enabled = true
        func fire() {
            if enabled { fireCount += 1 }
        }
    }

    /// Records every `(transcript, result)` pair `presentText` receives, in order.
    private final class FakeRenderSink {
        private(set) var calls: [(transcript: String?, result: VoiceSessionResult?)] = []
        func present(transcript: String?, result: VoiceSessionResult?) {
            calls.append((transcript, result))
        }
    }

    /// Records every `VoiceSessionPhase` `reportStatus` receives, in order — the
    /// double for the sink `AppCoordinator` uses to mirror the coordinator's phase
    /// into the menubar's `statusText` (Spec #1: "menubar and overlay both reflect
    /// the state", not just the physical hold).
    private final class FakePhaseReporter {
        private(set) var phases: [VoiceSessionPhase] = []
        func report(_ phase: VoiceSessionPhase) { phases.append(phase) }
    }

    // MARK: - Fixture

    private let mockTranscript = "What's the weather like today?"
    private let mockResult = VoiceSessionResult(
        transcript: "What's the weather like today?", summary: "It's 68°F and sunny.")

    private func makeSUT(
        driver: FakeDriver = FakeDriver(),
        overlay: FakeOverlaySink = FakeOverlaySink(),
        scheduler: FakeScheduler = FakeScheduler(),
        cue: FakeCue = FakeCue(),
        processingCue: FakeCue = FakeCue(),
        render: FakeRenderSink = FakeRenderSink(),
        phase: FakePhaseReporter = FakePhaseReporter()
    ) -> VoiceSessionCoordinator {
        VoiceSessionCoordinator(
            driver: driver,
            emit: overlay.send,
            playCue: cue.fire,
            scheduleAutoHide: scheduler.schedule,
            presentText: render.present,
            playProcessingCue: processingCue.fire,
            reportStatus: phase.report)
    }

    // MARK: - Happy path: down → up → transcript → result → auto-hide

    func testHappyPathEventSequence() {
        let driver = FakeDriver()
        let overlay = FakeOverlaySink()
        let scheduler = FakeScheduler()
        let sut = makeSUT(driver: driver, overlay: overlay, scheduler: scheduler)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        XCTAssertEqual(overlay.events, [.activate])
        XCTAssertEqual(driver.beginCalls, [.command])

        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing])
        XCTAssertEqual(driver.endCallCount, 1)

        driver.fire(.transcript(mockTranscript))
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing], "a transcript update is not an Overlay event")
        XCTAssertEqual(sut.transcript, mockTranscript)

        driver.fire(.result(mockResult))
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing, .presentResult])
        XCTAssertEqual(sut.result, mockResult)

        XCTAssertEqual(scheduler.scheduled.count, 1, "a result schedules exactly one auto-hide")
        scheduler.fireOldest()
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing, .presentResult, .dismiss])
    }

    // MARK: - Audio cue

    func testAudioCueFiresOnListenStartWhenEnabled() {
        let cue = FakeCue()
        cue.enabled = true
        let sut = makeSUT(cue: cue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))

        XCTAssertEqual(cue.fireCount, 1)
    }

    func testAudioCueDoesNotFireWhenDisabled() {
        let cue = FakeCue()
        cue.enabled = false
        let sut = makeSUT(cue: cue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))

        XCTAssertEqual(cue.fireCount, 0)
    }

    func testAudioCueDoesNotFireOnPTTUpOrDriverUpdates() {
        let driver = FakeDriver()
        let cue = FakeCue()
        let sut = makeSUT(driver: driver, cue: cue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(.transcript(mockTranscript))
        driver.fire(.result(mockResult))

        XCTAssertEqual(cue.fireCount, 1, "the cue only fires on the listen-start down-edge")
    }

    // MARK: - Processing-start audio cue (Spec #2: the "audio cue when processing
    // starts" setting was persisted but nothing read it)

    func testProcessingCueFiresOnPTTUpWhenEnabled() {
        let processingCue = FakeCue()
        processingCue.enabled = true
        let sut = makeSUT(processingCue: processingCue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))

        XCTAssertEqual(processingCue.fireCount, 1)
    }

    func testProcessingCueDoesNotFireWhenDisabled() {
        let processingCue = FakeCue()
        processingCue.enabled = false
        let sut = makeSUT(processingCue: processingCue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))

        XCTAssertEqual(processingCue.fireCount, 0)
    }

    func testProcessingCueDoesNotFireOnPTTDownOrDriverUpdates() {
        let driver = FakeDriver()
        let processingCue = FakeCue()
        let sut = makeSUT(driver: driver, processingCue: processingCue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        driver.fire(.transcript(mockTranscript))
        driver.fire(.result(mockResult))

        XCTAssertEqual(processingCue.fireCount, 0, "the processing cue only fires on the beginProcessing edge")
    }

    // MARK: - Phase reporting (Spec #1: the menubar must reflect Processing/Result,
    // not just the physical hotkey hold)

    func testReportsNothingOnListenStartAppCoordinatorOwnsThatText() {
        let phase = FakePhaseReporter()
        let sut = makeSUT(phase: phase)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))

        XCTAssertTrue(
            phase.phases.isEmpty,
            "listening is already rendered by AppCoordinator.reflectHold off the hotkey .down edge")
    }

    func testReportsProcessingThenResultThenIdleOnAutoHide() {
        let driver = FakeDriver()
        let scheduler = FakeScheduler()
        let phase = FakePhaseReporter()
        let sut = makeSUT(driver: driver, scheduler: scheduler, phase: phase)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        XCTAssertEqual(phase.phases, [.processing])

        driver.fire(.transcript(mockTranscript))
        XCTAssertEqual(phase.phases, [.processing], "a transcript update is not a phase change")

        driver.fire(.result(mockResult))
        XCTAssertEqual(phase.phases, [.processing, .result(mockResult)])

        XCTAssertEqual(scheduler.scheduled.count, 1)
        scheduler.fireOldest()
        XCTAssertEqual(phase.phases, [.processing, .result(mockResult), .idle], "auto-hide returns to idle")
    }

    // MARK: - PTT-restart while processing (LLD §10 flow control)

    func testNewPressWhileProcessingCancelsThePriorSessionAndRestarts() {
        let driver = FakeDriver()
        let overlay = FakeOverlaySink()
        let cue = FakeCue()
        let render = FakeRenderSink()
        let sut = makeSUT(driver: driver, overlay: overlay, cue: cue, render: render)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(.transcript(mockTranscript))  // the prior session got as far as a transcript…

        // …then a fresh press interrupts it before a result arrives.
        sut.handle(HotkeyActivation(hotkey: .dictation, phase: .down))

        XCTAssertEqual(driver.cancelCallCount, 1, "the still-in-flight prior session must be cancelled")
        XCTAssertEqual(driver.beginCalls, [.command, .dictation])
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing, .activate], "restart is legal from .processing")
        XCTAssertNil(sut.transcript, "the restart clears the interrupted session's stashed transcript")
        XCTAssertNil(sut.result)
        XCTAssertEqual(cue.fireCount, 2, "the cue fires again on the restart's listen-start")
        XCTAssertNil(render.calls.last?.transcript)
        XCTAssertNil(render.calls.last?.result)

        // The restarted session still resolves normally.
        sut.handle(HotkeyActivation(hotkey: .dictation, phase: .up))
        driver.fire(.result(mockResult))
        XCTAssertEqual(driver.cancelCallCount, 1, "resolving normally must not cancel again")
        XCTAssertEqual(overlay.events, [.activate, .beginProcessing, .activate, .beginProcessing, .presentResult])
    }

    func testFreshPressAfterAutoHideDoesNotCancelAnything() {
        // A session that already completed (result delivered, auto-hidden) has
        // nothing in flight — a later fresh press must not spuriously cancel.
        let driver = FakeDriver()
        let scheduler = FakeScheduler()
        let sut = makeSUT(driver: driver, scheduler: scheduler)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))
        driver.fire(.result(mockResult))
        scheduler.fireOldest()  // auto-hide → .dismiss → back to .hidden

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))

        XCTAssertEqual(driver.cancelCallCount, 0)
        XCTAssertEqual(driver.beginCalls, [.command, .command])
    }

    // MARK: - Transcript/result exposed for rendering

    func testTranscriptAndResultAreExposedAsTheySettle() {
        let driver = FakeDriver()
        let render = FakeRenderSink()
        let sut = makeSUT(driver: driver, render: render)

        XCTAssertNil(sut.transcript)
        XCTAssertNil(sut.result)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))

        driver.fire(.transcript(mockTranscript))
        XCTAssertEqual(sut.transcript, mockTranscript)
        XCTAssertNil(sut.result, "the result has not arrived yet")

        driver.fire(.result(mockResult))
        XCTAssertEqual(sut.transcript, mockTranscript)
        XCTAssertEqual(sut.result, mockResult)

        XCTAssertEqual(
            render.calls.map { $0.transcript },
            [nil, mockTranscript, mockTranscript],
            "reset-on-begin, then transcript, then transcript retained alongside the result")
        XCTAssertEqual(render.calls.map { $0.result }, [nil, nil, mockResult])
    }

    // MARK: - Illegal transitions are respected (defends against a stray edge)

    func testWhenTheOverlayRejectsActivateNoSessionIsStarted() {
        let driver = FakeDriver()
        let overlay = FakeOverlaySink()
        let cue = FakeCue()
        overlay.accepts = false
        let sut = makeSUT(driver: driver, overlay: overlay, cue: cue)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))

        XCTAssertTrue(driver.beginCalls.isEmpty)
        XCTAssertEqual(cue.fireCount, 0)
    }

    func testWhenTheOverlayRejectsBeginProcessingNothingDownstreamFires() {
        let driver = FakeDriver()
        let overlay = FakeOverlaySink()
        let processingCue = FakeCue()
        let phase = FakePhaseReporter()
        let sut = makeSUT(driver: driver, overlay: overlay, processingCue: processingCue, phase: phase)

        sut.handle(HotkeyActivation(hotkey: .command, phase: .down))
        overlay.accepts = false
        sut.handle(HotkeyActivation(hotkey: .command, phase: .up))

        XCTAssertEqual(driver.endCallCount, 0)
        XCTAssertEqual(processingCue.fireCount, 0, "beginProcessing was rejected — the processing cue must not fire")
        XCTAssertTrue(phase.phases.isEmpty, "beginProcessing was rejected — no processing phase should be reported")
    }
}
