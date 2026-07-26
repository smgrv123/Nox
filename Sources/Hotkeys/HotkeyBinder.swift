import Configuration

/// Which of Aide's two semantic hotkeys fired (User Story 12).
public enum SemanticHotkey: Equatable, Sendable, CaseIterable {
    case command
    case dictation

    /// Human-readable label for the menubar/overlay listening state (User Story 10).
    public var displayName: String {
        switch self {
        case .command: return "Command mode"
        case .dictation: return "Dictation mode"
        }
    }
}

/// The push-to-talk edge a raw key event represents: the hold began (`down`) or ended
/// (`up`). Derived from the tap's keyDown/keyUp (docs/05-lld.md §10 — push-to-talk is
/// the flow-control mechanism).
public enum HotkeyPhase: Equatable, Sendable {
    case down
    case up
}

/// A resolved semantic activation: *which* hotkey, and *which edge* of the hold.
public struct HotkeyActivation: Equatable, Sendable {
    public let hotkey: SemanticHotkey
    public let phase: HotkeyPhase

    public init(hotkey: SemanticHotkey, phase: HotkeyPhase) {
        self.hotkey = hotkey
        self.phase = phase
    }
}

/// The deep, pure binding logic behind `App/HotkeyManager.swift` (docs/05-lld.md §2.5,
/// §8). Built from `Settings.hotkeys`, it answers the only two questions the OS-bound
/// `CGEventTap` shell needs:
///
/// - **settings → chords** (at construction): the two bindings become `command` /
///   `dictation` chords;
/// - **event → activation** (`resolve`): given a raw `(keyCode, modifierFlags, phase)`,
///   which semantic hotkey is it and is it a push-to-talk down or up — or none?
///
/// It is a `Sendable` value with no mutable state, so the tap callback can hold one and
/// call `resolve` without locking; the callback stays trivially immediate (§10).
public struct HotkeyBinder: Equatable, Sendable {

    /// Chord that triggers command mode (default ⌥Space).
    public let command: HotkeyChord

    /// Chord that triggers dictation mode (default ⌃Space).
    public let dictation: HotkeyChord

    /// Direct chord injection — used by tests and any non-settings caller.
    public init(command: HotkeyChord, dictation: HotkeyChord) {
        self.command = command
        self.dictation = dictation
    }

    /// Build from the stored bindings (the "settings → chords" mapping).
    public init(hotkeys: Settings.Hotkeys) {
        self.command = HotkeyChord(hotkeys.commandMode)
        self.dictation = HotkeyChord(hotkeys.dictationMode)
    }

    /// The chord bound to a given semantic hotkey (the shell reads its base `keyCode`
    /// to reason about key release).
    public func chord(for hotkey: SemanticHotkey) -> HotkeyChord {
        switch hotkey {
        case .command: return command
        case .dictation: return dictation
        }
    }

    /// Which semantic hotkey — if any — a `(keyCode, modifiers)` chord matches.
    ///
    /// `command` is checked first, so a user who binds both to the *same* chord gets a
    /// deterministic (command-wins) result rather than an ambiguous one. In the default
    /// configuration the two chords are distinct (same key, different modifier), so
    /// command and dictation are never confused.
    public func semanticHotkey(
        forKeyCode keyCode: Int,
        modifiers: Set<Settings.HotkeyModifier>
    ) -> SemanticHotkey? {
        let chord = HotkeyChord(keyCode: keyCode, modifiers: modifiers)
        if chord == command { return .command }
        if chord == dictation { return .dictation }
        return nil
    }

    /// Turn one raw tap event into a semantic activation, or `nil` if it is not a bound
    /// hotkey. `eventFlags` is the `CGEventFlags` raw value; only the four chord
    /// modifiers are considered (Caps Lock/Fn/etc. are filtered out — see
    /// `HotkeyModifier.set(fromEventFlags:)`).
    public func resolve(keyCode: Int, eventFlags: UInt64, phase: HotkeyPhase) -> HotkeyActivation? {
        let modifiers = Settings.HotkeyModifier.set(fromEventFlags: eventFlags)
        guard let hotkey = semanticHotkey(forKeyCode: keyCode, modifiers: modifiers) else { return nil }
        return HotkeyActivation(hotkey: hotkey, phase: phase)
    }
}
