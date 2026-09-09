import AideCore
import Hotkeys
import Overlay

@testable import VoiceSession

final class FakeVoiceSessionDriver: VoiceSessionDriver {
    var onUpdate: ((VoiceSessionUpdate) -> Void)?
    private(set) var beginCalls: [VoiceSessionMode] = []
    private(set) var endCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var approveCallCount = 0
    private(set) var rejectCallCount = 0
    private(set) var confirmBackTimedOutCallCount = 0

    func begin(mode: VoiceSessionMode) { beginCalls.append(mode) }
    func end() { endCallCount += 1 }
    func cancel() { cancelCallCount += 1 }
    func approve() { approveCallCount += 1 }
    func reject() { rejectCallCount += 1 }
    func confirmBackTimedOut() { confirmBackTimedOutCallCount += 1 }
    func fire(_ update: VoiceSessionUpdate) { onUpdate?(update) }
}

final class FakeOverlaySink {
    private(set) var events: [OverlayEvent] = []
    var accepts = true
    func send(_ event: OverlayEvent) -> Bool {
        events.append(event)
        return accepts
    }
}

final class FakeScheduler {
    private(set) var scheduled: [() -> Void] = []
    func schedule(_ work: @escaping () -> Void) { scheduled.append(work) }
    func fireOldest() {
        guard !scheduled.isEmpty else { return }
        scheduled.removeFirst()()
    }
}

final class FakeCue {
    private(set) var fireCount = 0
    var enabled = true
    func fire() {
        if enabled { fireCount += 1 }
    }
}

final class FakeRenderSink {
    private(set) var calls: [(transcript: String?, result: VoiceSessionResult?)] = []
    func present(transcript: String?, result: VoiceSessionResult?) {
        calls.append((transcript, result))
    }
}

final class FakePhaseReporter {
    private(set) var phases: [VoiceSessionPhase] = []
    func report(_ phase: VoiceSessionPhase) { phases.append(phase) }
}

let voiceSessionMockTranscript = "What's the weather like today?"
let voiceSessionMockResult = VoiceSessionResult(
    transcript: "What's the weather like today?", summary: "It's 68°F and sunny.")

func makeVoiceSessionCoordinator(
    driver: FakeVoiceSessionDriver = FakeVoiceSessionDriver(),
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
