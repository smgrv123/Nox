import Foundation

/// Which of Aide's two push-to-talk modes started a voice session (mirrors
/// `Hotkeys.SemanticHotkey`, but `AideCore` sits beneath every pillar and cannot
/// depend on `Hotkeys` — this is the seam's own vocabulary). Command mode routes to a
/// skill; dictation mode inserts the transcript verbatim (docs/02-glossary.md).
public enum VoiceSessionMode: Equatable, Sendable {
    case command
    case dictation
}

/// The outcome of one voice session: the transcript plus what Aide did with it. Both
/// the P1 mock and the real local STT + routing stack (P2/P4) resolve to this same
/// shape, so nothing downstream (the Overlay, the coordinator) needs to change when
/// the mock is replaced (specs/P1 §"Architectural decisions" — the seam property).
public struct VoiceSessionResult: Equatable, Sendable {
    /// What the user said (the final recognized text).
    public let transcript: String
    /// A short human-readable summary of what Aide did — the Overlay's "Done" detail.
    public let summary: String

    public init(transcript: String, summary: String) {
        self.transcript = transcript
        self.summary = summary
    }
}

/// One update a `VoiceSessionDriver` reports as a session progresses: the transcript
/// becomes available first (as speech is recognized), then the full `result` once
/// dispatch/routing completes (docs/04-hld.md §13; User Stories 2, 39, 40, 41).
public enum VoiceSessionUpdate: Equatable, Sendable {
    case transcript(String)
    case result(VoiceSessionResult)
}

/// The seam (specs/P1 §"Architectural decisions" — "P1 depends only on `AideCore`
/// protocols"): the contract a voice-session engine must satisfy so the Phase-6
/// hotkey → Overlay wiring never has to change when the P1 mock is replaced by real
/// local STT + routing (P2/P4). `VoiceSessionCoordinator` (the `VoiceSession` module)
/// is the only caller; `MockVoiceSessionDriver` is P1's conformer.
///
/// One session is in flight at a time, driven by push-to-talk (docs/05-lld.md §10):
/// - `begin(mode:)` — PTT down: start capturing for `mode`.
/// - `end()` — PTT up: the utterance is complete; the driver resolves asynchronously,
///   delivering `.transcript` then `.result` through `onUpdate`.
/// - `cancel()` — a new press interrupted this session before it resolved; any update
///   still in flight for it must not be delivered.
///
/// `onUpdate` is always delivered on the **main actor** (docs/05-lld.md §10 —
/// Concurrency), matching every other UI-facing callback in this codebase
/// (`HotkeyManager.onActivation`, `PermissionGate`).
public protocol VoiceSessionDriver: AnyObject {
    /// Delivered on the main actor. The conformer is expected to have this set before
    /// its first `begin(mode:)` — `VoiceSessionCoordinator` sets it at construction.
    var onUpdate: ((VoiceSessionUpdate) -> Void)? { get set }

    /// Begin a session for `mode` (push-to-talk down).
    func begin(mode: VoiceSessionMode)

    /// End the current session (push-to-talk up); the driver reports its update(s)
    /// asynchronously through `onUpdate`.
    func end()

    /// Cancel the current session — a new press interrupted it mid-flight. No further
    /// `onUpdate` calls may fire for the cancelled session.
    func cancel()
}
