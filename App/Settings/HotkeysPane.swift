import AppKit
import Configuration
import Hotkeys
import SwiftUI

/// The hotkey-rebinding pane (Phase 9; User Stories 13, 14, 29): shows the two bound
/// push-to-talk chords and lets the user record a replacement for either. A recorded
/// chord takes effect immediately — no relaunch, via `AppCoordinator.rebindHotkey`
/// re-applying the binder to the live `HotkeyManager` — and persists through
/// `Configuration`.
///
/// The AppKit key capture here (a local `NSEvent` monitor) is a thin shell, verified
/// by running the app; the one rule it must honor — at least one modifier, so a bare
/// key can never hijack normal typing — is the pure, unit-tested
/// `HotkeyChordValidation` in the `Hotkeys` module.
struct HotkeysPane: View {
    @ObservedObject var coordinator: AppCoordinator

    /// Which hotkey is currently being recorded; `nil` when idle.
    @State private var recording: SemanticHotkey?
    /// The local event monitor installed while recording; torn down on stop.
    @State private var monitor: Any?
    /// Feedback after an invalid capture (no modifier held) — cleared on the next
    /// recording start or a successful capture.
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hotkeys")
                .font(.headline)

            row(for: .command, title: "Command Mode")
            row(for: .dictation, title: "Dictation Mode")

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(
                "Both are push-to-talk: hold to talk, release to send. A rebind must "
                    + "include at least one modifier key (⌘⌃⌥⇧) so it can't collide with normal typing."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private func row(for hotkey: SemanticHotkey, title: String) -> some View {
        HStack {
            Text(title)
                .frame(width: 110, alignment: .leading)
            Text(binding(for: hotkey).displayString)
                .monospaced()
                .foregroundStyle(.secondary)
            Spacer()
            Button(recording == hotkey ? "Press new keys…" : "Record…") {
                if recording == hotkey {
                    stopRecording()
                } else {
                    startRecording(hotkey)
                }
            }
        }
    }

    // `Configuration.Settings` is spelled out throughout this file because it also
    // imports SwiftUI, whose own `Settings` scene type would otherwise make the bare
    // name ambiguous.
    private func binding(for hotkey: SemanticHotkey) -> Configuration.Settings.HotkeyBinding {
        switch hotkey {
        case .command: return coordinator.settings.hotkeys.commandMode
        case .dictation: return coordinator.settings.hotkeys.dictationMode
        }
    }

    private func startRecording(_ hotkey: SemanticHotkey) {
        stopRecording()
        validationMessage = nil
        recording = hotkey
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event, for: hotkey)
            return nil  // swallow the key while recording — it must not type/act elsewhere
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = nil
    }

    /// Escape (keyCode 53) cancels the in-progress recording without saving;
    /// anything else is validated and, if legal, rebound immediately.
    private func handle(_ event: NSEvent, for hotkey: SemanticHotkey) {
        guard event.keyCode != HotkeyCaptureKeyCode.escape else {
            stopRecording()
            return
        }

        let modifiers = Configuration.Settings.HotkeyModifier.allCases.filter {
            event.modifierFlags.contains($0.appKitFlag)
        }

        guard
            let newBinding = HotkeyChordValidation.makeBinding(
                keyCode: Int(event.keyCode), modifiers: Set(modifiers))
        else {
            validationMessage = "Hold at least one modifier key, then press a base key."
            return
        }

        coordinator.rebindHotkey(hotkey, to: newBinding)
        validationMessage = nil
        stopRecording()
    }
}

/// Virtual key codes this pane cares about directly (Escape cancels recording).
private enum HotkeyCaptureKeyCode {
    static let escape: UInt16 = 53
}

extension Configuration.Settings.HotkeyModifier {
    /// This modifier's `NSEvent.ModifierFlags` bit — the AppKit-side counterpart of
    /// `HotkeyChord`'s `CGEventFlags` mapping, used only by the capture UI here.
    fileprivate var appKitFlag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .control: return .control
        case .option: return .option
        case .shift: return .shift
        }
    }

    /// This modifier's display glyph, e.g. `.command` → "⌘".
    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        }
    }
}

extension Configuration.Settings.HotkeyBinding {
    /// A human-readable chord label, e.g. "⌥Space" or "⌘⇧A" — display only; the
    /// binder itself always matches on `keyCode`/`modifiers`, never this string.
    /// Modifier glyphs are joined via `symbolOrder`, in standard macOS ⌃⌥⇧⌘ menu order.
    var displayString: String {
        let symbolOrder: [Configuration.Settings.HotkeyModifier] = [.control, .option, .shift, .command]
        let symbols = symbolOrder.filter { modifiers.contains($0) }.map(\.symbol)
        return symbols.joined() + Self.keyLabel(for: keyCode)
    }

    private static func keyLabel(for keyCode: Int) -> String {
        keyLabels[keyCode] ?? "Key \(keyCode)"
    }

    // Standard macOS ANSI virtual key codes (docs/05-lld.md §8 uses the same table via
    // CGEventFlags/keyboardEventKeycode) — display labels for the common bindable keys.
    private static let keyLabels: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete",
        53: "Escape", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
