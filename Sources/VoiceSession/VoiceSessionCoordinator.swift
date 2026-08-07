import AideCore
import Hotkeys
import Overlay

/// The coordinator's phase, delivered through the `reportStatus` sink
/// (`VoiceSessionCoordinator.init`) so a caller can mirror it into UI the Overlay
/// doesn't speak for on its own — `AppCoordinator` uses this to keep the menubar's
/// `statusText` in step with Processing/ShowingResult, not just the physical hotkey
/// hold. Deliberately has no `.listening` case — see `reportStatus`'s doc comment on
/// `VoiceSessionCoordinator` for why.
public enum VoiceSessionPhase: Equatable {
    /// PTT released; transcribing/routing (mirrors `OverlayEvent.beginProcessing`).
    case processing
    /// The dispatch outcome is ready (mirrors `OverlayEvent.presentResult`).
    case result(VoiceSessionResult)
    /// The Overlay has auto-hidden after showing a result — back to ambient idle.
    case idle
}

/// Phase 6's marquee orchestration — hotkey → Overlay → `VoiceSessionDriver` → Overlay
/// (docs/04-hld.md §13, docs/05-lld.md §10; User Stories 2, 8, 39, 40, 41).
/// `AppCoordinator` is the only caller.
///
/// Pure orchestration: no timers, no `NSSound`, no `NSPanel` reference — every effect
/// is an injected closure, so the full loop is testable headlessly with fakes
/// (`VoiceSessionCoordinatorTests`, specs/P1 §"Testing Decisions").
///
/// Flow:
/// - PTT down → `emit(.activate)`; if accepted, `playCue()` then `driver.begin(mode:)`.
///   Legal from `.hidden` (fresh) or `.processing` (PTT-restart, LLD §10) — a restart
///   first `driver.cancel()`s the still-in-flight prior session.
/// - PTT up → `emit(.beginProcessing)`; if accepted, `reportStatus(.processing)`,
///   `playProcessingCue()`, then `driver.end()`.
/// - `driver.onUpdate(.transcript)` → stash + `presentText` the transcript (the
///   Overlay stays `.processing`; there is no `OverlayEvent` for this).
/// - `driver.onUpdate(.result)` → stash + `presentText` the result, `emit(.presentResult)`,
///   `reportStatus(.result(value))`, then `scheduleAutoHide` the eventual
///   `emit(.dismiss)` + `reportStatus(.idle)`.
///
/// SEAM NOTE (code-review Standards #1 — clarifying comment only, nothing moved):
/// this type depends on the concrete `Overlay` and `Hotkeys` modules, not just an
/// `AideCore` protocol. That is intentional, not a seam-rule breach — `Overlay`,
/// `Hotkeys`, and `VoiceSession` are all modules *within* the single P1 pillar
/// (phases of P1, not separate pillars P1–P7 from `docs/07-implementation-pillars.md`),
/// so this is an intra-pillar dependency, which the independence rule permits. The
/// genuine cross-pillar seam — the one a later P2/P4 STT/routing engine swaps in
/// behind — is `driver: VoiceSessionDriver` below, an `AideCore`-only protocol; that
/// is, and must stay, the only dependency this type resolves against a pillar it
/// doesn't own.
public final class VoiceSessionCoordinator {

    private let driver: VoiceSessionDriver

    /// The Overlay sink — typically `OverlayController.send`. Returns whether the
    /// transition was legal, so this coordinator only reacts to activations the
    /// Overlay's state machine actually accepted (e.g. a stray PTT-down while
    /// `.showingResult`, which `.activate` does not permit, is silently ignored).
    private let emit: (OverlayEvent) -> Bool

    /// Fires once per accepted listen-start (fresh or PTT-restart). Whether a sound
    /// actually plays (gated on `settings.indicators.audioCueOnListen`) is the
    /// caller's decision — this module has no visibility into `Configuration`.
    private let playCue: () -> Void

    /// Fires once per accepted "PTT up" (processing has begun). Mirrors `playCue`
    /// for the processing-start cue; whether a sound actually plays (gated on
    /// `settings.indicators.audioCueOnProcessing`) is again the caller's decision.
    private let playProcessingCue: () -> Void

    /// Schedules the eventual auto-hide after a result is shown. Injected so tests
    /// fire it deterministically instead of waiting on a real timer.
    private let scheduleAutoHide: (@escaping () -> Void) -> Void

    /// Mirrors `transcript`/`result` out to the App layer (`OverlayController.present`)
    /// as they change, since a transcript update has no corresponding `OverlayEvent`
    /// for the caller to key off of.
    private let presentText: (String?, VoiceSessionResult?) -> Void

    /// Reports processing/result/idle phase milestones so a caller (`AppCoordinator`)
    /// can mirror them into UI the Overlay doesn't speak for — the menubar's
    /// `statusText`. Before this existed, the menubar only reflected the hotkey's
    /// physical down/up edges and read idle throughout Processing/ShowingResult even
    /// though the Overlay had moved on. Deliberately reports no `.listening` case:
    /// `AppCoordinator.reflectHold` already renders that (with the specific hotkey
    /// name) straight off the hotkey `.down` edge, so reporting it again here would
    /// just race a less specific string over top of it.
    private let reportStatus: (VoiceSessionPhase) -> Void

    /// Whether the current/most recent session's driver work is still outstanding —
    /// true from `begin` until its `result` arrives. Lets a PTT-restart know whether
    /// there is a prior session to `cancel()`.
    private var sessionInFlight = false

    /// The latest transcript, for rendering. `nil` before any session has produced one.
    public private(set) var transcript: String?

    /// The latest result, for rendering. `nil` before any session has produced one.
    public private(set) var result: VoiceSessionResult?

    public init(
        driver: VoiceSessionDriver,
        emit: @escaping (OverlayEvent) -> Bool,
        playCue: @escaping () -> Void,
        scheduleAutoHide: @escaping (@escaping () -> Void) -> Void,
        presentText: @escaping (String?, VoiceSessionResult?) -> Void = { _, _ in },
        playProcessingCue: @escaping () -> Void = {},
        reportStatus: @escaping (VoiceSessionPhase) -> Void = { _ in }
    ) {
        self.driver = driver
        self.emit = emit
        self.playCue = playCue
        self.scheduleAutoHide = scheduleAutoHide
        self.presentText = presentText
        self.playProcessingCue = playProcessingCue
        self.reportStatus = reportStatus
        driver.onUpdate = { [weak self] update in self?.apply(update) }
    }

    /// Route one hotkey edge into the loop — call alongside the existing menubar
    /// mirror from `AppCoordinator.startHotkeys()`'s `onActivation`.
    public func handle(_ activation: HotkeyActivation) {
        switch activation.phase {
        case .down: beginSession(mode: activation.hotkey.voiceSessionMode)
        case .up: endSession()
        }
    }

    private func beginSession(mode: VoiceSessionMode) {
        guard emit(.activate) else { return }
        if sessionInFlight {
            driver.cancel()
        }
        sessionInFlight = true
        stash(transcript: nil, result: nil)
        playCue()
        driver.begin(mode: mode)
    }

    private func endSession() {
        guard emit(.beginProcessing) else { return }
        reportStatus(.processing)
        playProcessingCue()
        driver.end()
    }

    private func apply(_ update: VoiceSessionUpdate) {
        switch update {
        case .transcript(let text):
            stash(transcript: text, result: result)
        case .result(let value):
            sessionInFlight = false
            stash(transcript: transcript, result: value)
            guard emit(.presentResult) else { return }
            reportStatus(.result(value))
            scheduleAutoHide { [weak self] in
                guard let self, self.emit(.dismiss) else { return }
                self.reportStatus(.idle)
            }
        }
    }

    private func stash(transcript: String?, result: VoiceSessionResult?) {
        self.transcript = transcript
        self.result = result
        presentText(transcript, result)
    }
}

extension SemanticHotkey {
    /// Maps the hotkey that started a session to the seam's mode vocabulary
    /// (`AideCore` can't depend on `Hotkeys`, so the two enums exist independently).
    fileprivate var voiceSessionMode: VoiceSessionMode {
        switch self {
        case .command: return .command
        case .dictation: return .dictation
        }
    }
}
