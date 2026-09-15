import AppKit
import ApplicationServices
import Carbon
import Dictation
import Foundation

/// AppKit shell for `TextInserting` (LLD §4.7 deviation: paste-only, not AX-first).
/// AX insertion was removed — `AXUIElementSetAttributeValue(..., kAXSelectedTextAttribute,
/// ...)` returns `.success` when the attribute write is *accepted*, not when text is
/// actually inserted; Electron, Catalyst, and custom text views accept and discard
/// it, so it had zero confirmed successes in real use. Synthetic ⌘V runs on the main
/// thread. Clipboard save/restore is best-effort and always attempted after paste so
/// Aide does not silently clobber the pasteboard. Not unit-tested (`HotkeyManager`
/// precedent); `just app` is the compile gate.
///
/// Before posting the keystroke, `insert(_:)` checks `IsSecureEventInputEnabled()`
/// (Carbon) — when macOS Secure Input is on (any password field focused anywhere on
/// the system), synthetic keystrokes are silently discarded, so ⌘V can never work.
/// Detecting that in advance means we return a failure without ever touching the
/// user's clipboard, instead of clobbering it for a paste that was never going to
/// land.
///
/// `AXIsProcessTrusted()` is still required — posting synthetic ⌘V needs Accessibility
/// permission exactly as the removed AX write did — so `resolveFocus()` keeps
/// reporting it.
@MainActor
final class TextInserterLive: TextInserting {

    /// How long to wait after posting synthetic ⌘V before restoring the user's
    /// original clipboard. Posting ⌘V only *queues* the keystroke — the target app
    /// reads the pasteboard asynchronously, on its own schedule — so this is a bet on
    /// how long that takes. Too short and we restore before the target app has read
    /// the dictated text, so the paste silently produces nothing (or re-pastes the
    /// user's previous clipboard); too long and the user's clipboard sits clobbered
    /// for longer than necessary. 300-500ms is the sane band; 400ms is the current
    /// pick. Was 80ms (PROVISIONAL, never tuned) — an app under load, e.g. `xcodebuild`
    /// running in the background, can easily exceed that, which is the leading
    /// explanation for an observed silent paste failure in Ghostty.
    private static let pasteSettleNanoseconds: UInt64 = 400_000_000
    private static let vKeyCode: CGKeyCode = 0x09

    /// nspasteboard.org "concealed"/"transient" convention: honoured by Raycast,
    /// Maccy, Alfred, Paste, and others as a signal to skip recording the pasteboard
    /// item into clipboard history. Every dictation now transits the pasteboard, so
    /// without this every dictated utterance would otherwise land permanently in
    /// clipboard history. This is a convention, not enforcement — a manager that
    /// doesn't honour it will still record the item.
    private static let clipboardManagerSkipTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    func resolveFocus() async -> InsertionFocus {
        InsertionFocus(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            accessibilityTrusted: AXIsProcessTrusted())
    }

    func insert(_ text: String) async -> InsertionResult {
        if IsSecureEventInputEnabled() {
            return .failed(.secureInput)
        }
        return await insertViaPaste(text)
            ? .insertedViaPaste
            : .failed(.pasteFailed(detail: "Couldn't paste."))
    }

    func copyToClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func insertViaPaste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = Self.snapshot(pasteboard)
        pasteboard.clearContents()
        let wrote = Self.writeConcealed(text, to: pasteboard)
        guard wrote else {
            Self.restore(snapshot, onto: pasteboard)
            return false
        }
        defer { Self.restore(snapshot, onto: pasteboard) }
        guard Self.postCommandV() else {
            return false
        }
        try? await Task.sleep(nanoseconds: Self.pasteSettleNanoseconds)
        return true
    }

    /// Writes `text` as the pasteboard's string content along with the clipboard-
    /// manager skip markers, in one `declareTypes`/write batch — the markers must be
    /// present on the same pasteboard-change event as the string so a manager
    /// observing the change sees them together, not the string first and markers
    /// added after.
    private static func writeConcealed(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for type in clipboardManagerSkipTypes {
            item.setData(Data(), forType: type)
        }
        return pasteboard.writeObjects([item])
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        pasteboard.pasteboardItems?.map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        } ?? []
    }

    private static func restore(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
        onto pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        for itemTypes in snapshot {
            let item = NSPasteboardItem()
            for (type, data) in itemTypes {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }

    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
