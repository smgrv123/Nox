import AideCore
import Foundation

/// The P1 conformer of the `VoiceSessionDriver` seam (specs/P1 §"Architectural
/// decisions"): yields a canned transcript, then a canned result, proving the
/// hotkey → Overlay loop end-to-end before real STT/routing exist (P2/P4). A real
/// engine swaps in later by conforming to the same protocol — no change to
/// `VoiceSessionCoordinator` or anything upstream of it.
///
/// Timing is **injected** (`scheduleTranscript`/`scheduleResult`) rather than baked in
/// with `Task.sleep`/`DispatchQueue` calls a test would have to wait on. The defaults
/// use a real timer for the running app; `VoiceSessionCoordinatorTests` and
/// `MockVoiceSessionDriverTests` substitute a synchronous fake so the suite has no
/// real delays (specs/P1 §"Testing Decisions").
public final class MockVoiceSessionDriver: VoiceSessionDriver {

    public var onUpdate: ((VoiceSessionUpdate) -> Void)?

    private let transcript: String
    private let result: VoiceSessionResult
    private let scheduleTranscript: (@escaping () -> Void) -> Void
    private let scheduleResult: (@escaping () -> Void) -> Void

    /// Bumped by `begin`/`cancel` so a scheduled callback from a superseded session
    /// (the user pressed again before this one resolved) is silently dropped even if
    /// it fires late — the driver-level half of the "a new press cancels the prior"
    /// rule (docs/05-lld.md §10); the Overlay-visible half lives in
    /// `VoiceSessionCoordinator`.
    private var generation = 0

    public init(
        transcript: String = "What's the weather like today?",
        result: VoiceSessionResult = VoiceSessionResult(
            transcript: "What's the weather like today?",
            summary: "It's 68°F and sunny in San Francisco."),
        scheduleTranscript: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        },
        scheduleResult: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    ) {
        self.transcript = transcript
        self.result = result
        self.scheduleTranscript = scheduleTranscript
        self.scheduleResult = scheduleResult
    }

    public func begin(mode: VoiceSessionMode) {
        generation += 1
    }

    public func end() {
        let sessionGeneration = generation
        scheduleTranscript { [weak self] in
            guard let self, self.generation == sessionGeneration else { return }
            self.onUpdate?(.transcript(self.transcript))
            self.scheduleResult { [weak self] in
                guard let self, self.generation == sessionGeneration else { return }
                self.onUpdate?(.result(self.result))
            }
        }
    }

    public func cancel() {
        generation += 1
    }
}
