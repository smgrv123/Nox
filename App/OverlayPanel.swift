import AppKit
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

    /// The pure, guarded state machine (the tested core).
    private var machine = OverlayStateMachine()

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

    /// Bottom-center of the active screen (matches the `overlay_position` default).
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 120)
        panel.setFrameOrigin(origin)
    }
}

/// An `NSPanel` that can **never** become key or main, so showing it never pulls
/// keyboard focus away from the user's frontmost app (docs/04-hld.md §13.1).
final class NonActivatingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
