import AideCore
import XCTest

@testable import VoiceSession

/// `MockVoiceSessionDriver` — the P1 `VoiceSessionDriver` conformer. Its scheduling is
/// injected (no `Task.sleep`/real `DispatchQueue`), so these tests fire the "clock"
/// manually and never wait on a real timer (specs/P1 §"Testing Decisions").
final class MockVoiceSessionDriverTests: XCTestCase {

    /// Captures scheduled work instead of running it, standing in for
    /// `scheduleTranscript`/`scheduleResult`.
    private final class WorkQueue {
        private(set) var items: [() -> Void] = []
        func schedule(_ work: @escaping () -> Void) { items.append(work) }
        func fireAll() {
            let pending = items
            items.removeAll()
            for work in pending { work() }
        }
    }

    func testYieldsTranscriptThenResultOnlyWhenTheScheduledWorkFires() {
        let transcriptQueue = WorkQueue()
        let resultQueue = WorkQueue()
        let expectedResult = VoiceSessionResult(transcript: "hi", summary: "did it")
        let sut = MockVoiceSessionDriver(
            transcript: "hi",
            result: expectedResult,
            scheduleTranscript: transcriptQueue.schedule,
            scheduleResult: resultQueue.schedule)
        var updates: [VoiceSessionUpdate] = []
        sut.onUpdate = { updates.append($0) }

        sut.begin(mode: .command)
        sut.end()
        XCTAssertTrue(updates.isEmpty, "nothing delivered until the scheduled work fires")

        transcriptQueue.fireAll()
        XCTAssertEqual(updates, [.transcript("hi")])

        resultQueue.fireAll()
        XCTAssertEqual(updates, [.transcript("hi"), .result(expectedResult)])
    }

    func testCancelSuppressesAnAlreadyScheduledUpdate() {
        let transcriptQueue = WorkQueue()
        let resultQueue = WorkQueue()
        let sut = MockVoiceSessionDriver(
            scheduleTranscript: transcriptQueue.schedule, scheduleResult: resultQueue.schedule)
        var updates: [VoiceSessionUpdate] = []
        sut.onUpdate = { updates.append($0) }

        sut.begin(mode: .command)
        sut.end()
        sut.cancel()  // interrupted before the scheduled transcript work fired

        transcriptQueue.fireAll()

        XCTAssertTrue(updates.isEmpty, "a cancelled session's scheduled update must not be delivered")
    }

    func testANewSessionAfterCancelDeliversWhileTheStaleOneStaysSuppressed() {
        let transcriptQueue = WorkQueue()
        let resultQueue = WorkQueue()
        let sut = MockVoiceSessionDriver(
            scheduleTranscript: transcriptQueue.schedule, scheduleResult: resultQueue.schedule)
        var updates: [VoiceSessionUpdate] = []
        sut.onUpdate = { updates.append($0) }

        sut.begin(mode: .command)
        sut.end()
        sut.cancel()
        sut.begin(mode: .dictation)
        sut.end()

        // Both the stale (cancelled) and the fresh session's work are pending; only
        // the fresh one's generation still matches when it fires.
        XCTAssertEqual(transcriptQueue.items.count, 2)
        transcriptQueue.fireAll()

        XCTAssertEqual(updates.count, 1, "only the fresh session's transcript delivers")
    }
}
