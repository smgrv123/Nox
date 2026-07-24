import AppKit
import CoreGraphics
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

    func start() {
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
            onStatusChange?("⚠️ Needs Accessibility permission")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        logger.info("Event tap installed. Hold F13 to test the Push-to-Talk path.")
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
