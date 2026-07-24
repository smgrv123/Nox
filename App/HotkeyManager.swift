import AppKit
import CoreGraphics
import Permissions
import os

/// Global Push-to-Talk hotkey capture via `CGEventTap` (locked decision #4).
///
/// A session event tap is the mechanism used by comparable dictation tools: it
/// yields clean keyDown/keyUp pairs (needed to know when the user starts and stops
/// holding) and can bind modifier-only keys. It requires the **Accessibility**
/// permission — which Aide needs anyway for Text Insertion — so there is no extra
/// permission cost (see docs/04-hld.md §13, docs/05-lld.md §8).
///
/// Tracer-bullet scope: install the tap, report success/failure (so a missing
/// permission is legible, not silent), and log keyDown/keyUp of a placeholder
/// Push-to-Talk key. Real hotkey binding + audio capture arrive with the STT
/// subsystem (docs/04-hld.md §3).
final class HotkeyManager {

    /// Placeholder Push-to-Talk keycode: F13 (0x69). Real binding is user-configurable later.
    private static let pushToTalkKeyCode: Int64 = 0x69

    private let logger = Logger(subsystem: "com.aide.Aide", category: "Hotkey")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Called on the main actor with a short status string for the menubar UI.
    var onStatusChange: ((String) -> Void)?

    /// P7 fix-it seam (User Stories 15, 26): reports the Accessibility grant state of the
    /// hotkey path. `nil` means the tap installed (granted / recovered); a non-nil
    /// `PermissionAdvice` carries the hint + exact-pane deep-link for the menubar (and,
    /// later, the overlay) to render instead of failing silently. Called on the tap thread;
    /// the app hops it to the main actor.
    var onAccessibilityStatus: ((PermissionAdvice?) -> Void)?

    /// Re-attempt the tap install (P7 recovery): after the user grants Accessibility in
    /// System Settings, this installs the tap and clears the fix-it. Idempotent — a no-op
    /// once the tap is already live.
    func retry() {
        start()
    }

    func start() {
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
                    manager.handle(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            logger.error("Event tap creation failed — Accessibility permission not granted.")
            // P7: surface the actionable fix-it (hint + exact-pane deep-link) rather than a
            // bare/silent message. The tap-create failure IS the AX-denied signal for the
            // hotkey path, so we map it straight to the `.accessibility` / `.denied` advice.
            onStatusChange?("⚠️ Needs Accessibility permission")
            onAccessibilityStatus?(PermissionAdvice.make(for: .accessibility, status: .denied))
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        logger.info("Event tap installed. Hold F13 to test the Push-to-Talk path.")
        onStatusChange?("Ready — hold F13 to test")
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
            onStatusChange?("⚠️ Needs Accessibility permission")
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            logger.notice("Re-enabled the Push-to-Talk event tap after wake.")
        }
        onStatusChange?("Ready — hold F13 to test")
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.pushToTalkKeyCode else { return }
        switch type {
        case .keyDown:
            logger.info("Push-to-Talk down → listening…")
            onStatusChange?("🎙️ Listening…")
        case .keyUp:
            logger.info("Push-to-Talk up → processing…")
            onStatusChange?("Ready — hold F13 to test")
        default:
            break
        }
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
