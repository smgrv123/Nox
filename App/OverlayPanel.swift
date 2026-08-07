import AppKit
import Configuration
import Overlay
import SwiftUI

/// The Overlay's on-screen shell: a **non-activating** `NSPanel` hosting SwiftUI,
/// bound to the pure `OverlayStateMachine` (docs/04-hld.md §13.1). It reports what
/// Aide is doing **without stealing keyboard focus** from the app the user is typing
/// in (User Stories 5, 6, 7) — the load-bearing property for Dictation/Text Insertion.
///
/// How focus is never stolen (all three together):
/// 1. `NonActivatingOverlayPanel` overrides `canBecomeKey`/`canBecomeMain` to `false`.
/// 2. the panel carries the `.nonactivatingPanel` style mask.
/// 3. it is shown with `orderFrontRegardless()`, **never** `makeKeyAndOrderFront(_:)`.
///
/// Concurrency: this is a thin UI shell that mirrors the repo's existing idiom
/// (`AppCoordinator`, `HotkeyManager`) — a plain class whose methods are only ever
/// called on the main thread (SwiftUI menu actions + the main-thread lifecycle
/// hooks). All overlay UI therefore runs on the main actor (specs/P1 §"Concurrency
/// rules"). The pure decision lives in `OverlayStateMachine`; this only renders it.
final class OverlayController: ObservableObject {

    /// The current Overlay state the SwiftUI view renders. Mutated only on the main
    /// thread via `send` / `debugForce`, which keep it in step with `machine`.
    @Published private(set) var state: OverlayState = .initial

    /// The latest transcript from the current/most recent voice session (Phase 6;
    /// User Stories 2, 39, 40), shown while `.processing`. `nil` before any session
    /// has produced one. Set via `present(transcript:result:)`.
    @Published private(set) var transcript: String?

    /// The latest result summary from the current/most recent voice session
    /// (Phase 6), shown once `.showingResult`. `nil` before a session has produced a
    /// result.
    @Published private(set) var result: String?

    /// Whether to render the Local/Cloud indicator badge (Phase 9; User Stories 29,
    /// 30). Mirrors `settings.indicators.showLocalCloudIndicator`; `AppCoordinator`
    /// keeps it in sync via `applyIndicatorSettings` on load and on every persisted
    /// change. P1 always shows a static "LOCAL" badge when this is on — the live
    /// LOCAL/CLOUD state it will eventually reflect is P6 (BYOK cloud escalation) scope.
    /// `Configuration.Settings` is spelled out below because this file also imports
    /// SwiftUI, whose own `Settings` scene type would otherwise make the bare name
    /// ambiguous.
    @Published private(set) var showLocalCloudIndicator = Configuration.Settings.Indicators().showLocalCloudIndicator

    /// The pure, guarded state machine (the tested core).
    private var machine = OverlayStateMachine()

    /// Where the panel is shown on screen (Phase 9; User Story 29), kept in sync with
    /// `settings.indicators.overlayPosition` by `applyIndicatorSettings`. Defaults to
    /// `Configuration.Settings.Indicators()`'s default (bottom-center) so a show before
    /// settings load still lands somewhere sane.
    private var overlayPosition = Configuration.Settings.Indicators().overlayPosition

    /// Lazily created on first show so app launch never touches the window server
    /// until the Overlay is actually needed.
    private var panel: NSPanel?

    /// Drive the Overlay with a real `OverlayEvent` (the Phase-6 voice driver's path).
    /// Illegal transitions are rejected by the machine and leave the Overlay unchanged.
    ///
    /// - Returns: `true` if the event was a legal transition.
    @discardableResult
    func send(_ event: OverlayEvent) -> Bool {
        let applied = machine.send(event)
        if applied { syncToState() }
        return applied
    }

    /// PHASE 4 (TEMPORARY debug trigger): jump the Overlay straight to `target` so each
    /// state's visual can be verified now, before the real driver exists. Seeds a fresh
    /// machine at `target` — it does **not** weaken the guards (those live in `send`,
    /// covered exhaustively by `OverlayStateMachineTests`). Removed once Phase 6's voice
    /// loop and Phase 10's onboarding exercise these paths (mirrors Phase 3's debug
    /// audio-cue toggle). See plans/P1 Phase 4 + "Execution notes".
    func debugForce(_ target: OverlayState) {
        machine = OverlayStateMachine(state: target)
        syncToState()
    }

    /// PHASE 6: set by `VoiceSessionCoordinator`'s injected `presentText` sink as a
    /// session progresses (transcript first, then result) — see `AppCoordinator`.
    /// Both reset to `nil` at the start of a fresh/restarted session so a stale value
    /// never lingers into the next one.
    func present(transcript: String?, result: String?) {
        self.transcript = transcript
        self.result = result
    }

    /// Apply the user's overlay-position + indicator-visibility preferences (Phase 9;
    /// User Stories 29, 30). Called by `AppCoordinator` once after settings load and
    /// again after every persisted change, so the **next** `showPanel()` reflects the
    /// current settings — no relaunch needed.
    func applyIndicatorSettings(_ indicators: Configuration.Settings.Indicators) {
        overlayPosition = indicators.overlayPosition
        showLocalCloudIndicator = indicators.showLocalCloudIndicator
    }

    /// Reflect `machine.state` into the published state and the panel's visibility.
    private func syncToState() {
        state = machine.state
        if state.isVisible {
            showPanel()
        } else {
            panel?.orderOut(nil)
        }
    }

    /// Show the panel **without** activating Aide or taking key focus.
    private func showPanel() {
        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let hosting = NSHostingController(rootView: OverlayView(controller: self))
        let created = NonActivatingOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true)
        created.contentViewController = hosting
        created.isFloatingPanel = true
        created.level = .floating
        created.hidesOnDeactivate = false
        created.becomesKeyOnlyIfNeeded = true
        created.worksWhenModal = false
        created.isMovableByWindowBackground = false
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = false  // the SwiftUI card draws its own shadow
        created.ignoresMouseEvents = true  // Phase 4 renders visuals only; no controls yet
        // Ride across Spaces and over full-screen apps without ever activating.
        created.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel = created
        return created
    }

    /// Top- or bottom-center of the active screen, per `overlayPosition` (Phase 9;
    /// User Story 29 — defaults to bottom-center, matching `Settings.Indicators`'s
    /// default).
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let originX = visible.midX - size.width / 2
        let originY: CGFloat
        switch overlayPosition {
        case .bottomCenter:
            originY = visible.minY + 120
        case .topCenter:
            originY = visible.maxY - size.height - 60
        }
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

/// An `NSPanel` that can **never** become key or main, so showing it never pulls
/// keyboard focus away from the user's frontmost app (docs/04-hld.md §13.1).
final class NonActivatingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
