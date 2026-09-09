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
/// becomes available first (as speech is recognized), then a structured outcome
/// (docs/04-hld.md §13; User Stories 2, 39, 40, 41). Terminal outcomes are `.result`,
/// `.confirmBack`, `.promptBack`, or `.hardBlocked`.
public enum VoiceSessionUpdate: Equatable, Sendable {
    case transcript(String)
    case result(VoiceSessionResult)
    case confirmBack(ConfirmBackInfo)
    case promptBack(String, String?)
    case hardBlocked(String, String)
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
///   delivering `.transcript` then a terminal update through `onUpdate`. That
///   terminal update may be `.result`, `.confirmBack`, `.promptBack`, or
///   `.hardBlocked`.
/// - `cancel()` — a new press interrupted this session before it resolved; any update
///   still in flight for it must not be delivered.
/// - `approve()` / `reject()` — Confirm-Back: re-dispatch or drop the stashed intent
///   (default no-ops; command-mode conformers override).
///
/// `onUpdate` is always delivered on the **main actor** (docs/05-lld.md §10 —
/// Concurrency), matching every other UI-facing callback in this codebase
/// (`HotkeyManager.onActivation`, `PermissionGate`).
public protocol VoiceSessionDriver: AnyObject {
    /// Delivered on the main actor. The conformer is expected to have this set before
    /// its first `begin(mode:)` — `VoiceSessionCoordinator` sets it at construction.
    /// After `end()`, may deliver `.transcript` then `.result`, `.confirmBack`,
    /// `.promptBack`, or `.hardBlocked`.
    var onUpdate: ((VoiceSessionUpdate) -> Void)? { get set }

    /// Begin a session for `mode` (push-to-talk down).
    func begin(mode: VoiceSessionMode)

    /// End the current session (push-to-talk up); the driver reports its update(s)
    /// asynchronously through `onUpdate` (`.transcript` then `.result` /
    /// `.confirmBack` / `.promptBack` / `.hardBlocked`).
    func end()

    /// Cancel the current session — a new press interrupted it mid-flight. No further
    /// `onUpdate` calls may fire for the cancelled session.
    func cancel()

    /// Confirm-Back approved: re-dispatch the stashed intent, bypassing the gate.
    func approve()

    /// Confirm-Back rejected: drop the stashed intent without running it.
    func reject()

    /// Confirm-Back's safety-net timeout fired — the user answered neither Approve
    /// nor Reject in time (docs/04-hld.md §13.1; `VoiceSessionCoordinator
    /// .scheduleConfirmBackTimeoutToIdle`). The safety guarantee is identical to an
    /// explicit `reject()`: the stashed intent must never run. Most conformers have
    /// no reason to treat this differently from `reject()` — the default forwards to
    /// it. `DictationDriver` overrides this: silently dropping dictated text the user
    /// never got a chance to approve *or* reject is its own failure mode (the text is
    /// gone either way), so it copies the stashed text to the clipboard instead of
    /// just discarding it, without ever inserting it.
    func confirmBackTimedOut()
}

extension VoiceSessionDriver {
    public func approve() {}
    public func reject() {}
    public func confirmBackTimedOut() { reject() }
}
