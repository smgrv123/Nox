import AppKit
import ApplicationServices
import Dictation
import Foundation

/// AppKit/AX shell for `TextInserting` (LLD §4.7). AX + synthetic ⌘V run on the
/// main thread. Clipboard save/restore is best-effort and always attempted after
/// paste so Aide does not silently clobber the pasteboard. Not unit-tested
/// (`HotkeyManager` precedent); `just app` is the compile gate.
@MainActor
final class TextInserterLive: TextInserting {

    private static let pasteSettleNanoseconds: UInt64 = 80_000_000
    private static let vKeyCode: CGKeyCode = 0x09

    func resolveFocus() async -> InsertionFocus {
        InsertionFocus(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            accessibilityTrusted: AXIsProcessTrusted())
    }

    func insert(_ text: String, plan: InsertionPlan) async -> InsertionResult {
        switch plan {
        case .axOnly:
            return insertViaAX(text)
                ? .insertedViaAX
                : .failed(reason: "Couldn't insert via Accessibility.")
        case .pasteOnly:
            return await insertViaPaste(text)
                ? .insertedViaPaste
                : .failed(reason: "Couldn't paste.")
        case .axThenPaste:
            if insertViaAX(text) { return .insertedViaAX }
            return await insertViaPaste(text)
                ? .insertedViaPaste
                : .failed(reason: "Couldn't insert via Accessibility or paste.")
        }
    }

    func copyToClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func insertViaAX(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let copyError = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard copyError == .success, let focused else { return false }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let setError = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return setError == .success
    }

    private func insertViaPaste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = Self.snapshot(pasteboard)
        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
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
