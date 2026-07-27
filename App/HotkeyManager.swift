import AppKit
import CoreGraphics
import Hotkeys
import Permissions
import os

/// Global push-to-talk hotkey capture via `CGEventTap` (locked decision #4).
///
/// A session event tap is the mechanism used by comparable dictation tools: it yields
/// clean keyDown/keyUp pairs (needed to know when the user starts and stops holding)
/// and sees events from any foreground app. It requires the **Accessibility**
/// permission — which Aide needs anyway for Text Insertion — so there is no extra
/// permission cost (docs/04-hld.md §13, docs/05-lld.md §8).
///
/// This shell is deliberately thin: it installs the tap and forwards raw events to the
/// pure `HotkeyBinder` (the tested "settings → chords" + "event → semantic hotkey"
/// logic in the `Hotkeys` module). Concurrency rules it MUST honour (docs/05-lld.md
/// §10): the tap callback returns immediately, and all reaction to an event — the
/// binder lookup, the tiny held-hotkey state, and the UI-facing callbacks — happens on
/// the **main actor**.
final class HotkeyManager {

    /// The idle/ready status shown when no hotkey is held (single source so `start`
    /// and `revalidate` never drift).
    private static let readyStatus = "Ready — hold a hotkey to talk"
    /// The actionable Accessibility-denied message (User Story 15): never fail silently.
    private static let accessibilityNeededStatus =
        "⚠️ Hotkeys need Accessibility access. Open the menu → “Open Accessibility Settings…”, "
        + "enable Aide, then relaunch."

    private let logger = Logger(subsystem: "com.aide.Aide", category: "Hotkey")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The chords to match against, derived from `Settings.hotkeys`. Set by `start`;
    /// read only on the main actor.
    private var binder: HotkeyBinder?

    /// The hotkey currently held down (push-to-talk). Main-actor-only state; lets us
    /// end the hold reliably even if the base key's modifier is released a hair before
    /// the key itself (so the tap reports the keyUp without the modifier bit).
    private var activeHotkey: SemanticHotkey?

    /// Semantic push-to-talk edge, delivered on the main actor. Later phases hook the
    /// real voice session here; today `AppCoordinator` turns it into menubar status.
    var onActivation: ((HotkeyActivation) -> Void)?

    /// Lifecycle / error status (installed, or Accessibility-denied), on the main actor.
    var onStatus: ((String) -> Void)?

    /// P7 fix-it seam (User Stories 15, 26): reports the Accessibility grant state of the
    /// hotkey path. `nil` means the tap installed (granted / recovered); a non-nil
    /// `PermissionAdvice` carries the hint + exact-pane deep-link for the menubar (and,
    /// later, the overlay) to render instead of failing silently. Called on the main actor.
    var onAccessibilityStatus: ((PermissionAdvice?) -> Void)?

    /// Re-attempt the tap install (P7 recovery): after the user grants Accessibility in
    /// System Settings, this re-runs `start` with the binder already in hand, installing
    /// the tap and clearing the fix-it. A no-op if `start` was never called or the tap is
    /// already live.
    func retry() {
        guard let binder else { return }
        start(binder: binder)
    }

    /// Install the tap and begin matching against `binder`'s chords. Call after settings
    /// are loaded so the bindings reflect the user's configuration, not a placeholder.
    func start(binder: HotkeyBinder) {
        self.binder = binder
        // Idempotent: never stack a second tap (keeps `retry()` safe to call repeatedly).
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, refcon in
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
                    // Read the few primitive fields here (cheap) and hand off to the
                    // main actor. NOTHING heavy runs in the tap — it returns immediately.
                    manager.enqueue(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            // AX not granted: tapCreate fails. Surface an actionable message — never fail
            // silently (User Story 15) — and the P7 fix-it (hint + exact-pane deep-link).
            // The tap-create failure IS the AX-denied signal for the hotkey path.
            logger.error("Event tap creation failed — Accessibility permission not granted.")
            onStatus?(Self.accessibilityNeededStatus)
            onAccessibilityStatus?(PermissionAdvice.make(for: .accessibility, status: .denied))
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        logger.info("Event tap installed; matching the two bound push-to-talk hotkeys.")
        onStatus?(Self.readyStatus)
        // P7: tap installed ⇒ Accessibility is granted; clear any prior fix-it (recovery).
        onAccessibilityStatus?(nil)
    }

    /// Re-assert the event tap after a system event that can silently disable it —
    /// notably sleep/wake (PHASE 11; User Story 37). macOS may disable a tap across
    /// sleep; re-enabling it keeps Push-to-Talk working so the app resumes usable
    /// rather than going quietly dead. No tap installed → surface the (unchanged)
    /// Accessibility-needed state instead of failing silently (User Story 38).
    func revalidate() {
        guard let tap = eventTap else {
            logger.notice("Wake revalidation: no event tap installed (Accessibility not granted?).")
            onStatus?(Self.accessibilityNeededStatus)
            onAccessibilityStatus?(PermissionAdvice.make(for: .accessibility, status: .denied))
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            logger.notice("Re-enabled the Push-to-Talk event tap after wake.")
        }
        onStatus?(Self.readyStatus)
    }

    /// Runs on the tap's run-loop thread. Extracts primitives and hops to the main
    /// actor; it never touches `binder`/`activeHotkey` itself (those are main-only).
    private func enqueue(type: CGEventType, event: CGEvent) {
        let phase: HotkeyPhase
        switch type {
        case .keyDown: phase = .down
        case .keyUp: phase = .up
        default: return  // flagsChanged etc. are not push-to-talk edges.
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        Task { @MainActor [weak self] in
            self?.process(keyCode: keyCode, eventFlags: flags, phase: phase)
        }
    }

    /// Main-actor reaction: ask the binder for the decision (normal chord match, or its
    /// release-edge fallback — see `HotkeyBinder.resolve(keyCode:eventFlags:phase:activeHotkey:)`)
    /// and update the held-hotkey state from the result.
    @MainActor
    private func process(keyCode: Int, eventFlags: UInt64, phase: HotkeyPhase) {
        guard let binder else { return }
        guard
            let activation = binder.resolve(
                keyCode: keyCode, eventFlags: eventFlags, phase: phase, activeHotkey: activeHotkey)
        else { return }

        switch activation.phase {
        case .down: activeHotkey = activation.hotkey
        case .up: activeHotkey = nil
        }
        onActivation?(activation)
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
}
