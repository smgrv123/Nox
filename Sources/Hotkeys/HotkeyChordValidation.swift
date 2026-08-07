import Configuration

/// Pure validation + construction for a **freshly captured** hotkey chord, before it
/// becomes a `Settings.HotkeyBinding` (Phase 9; User Story 14 — rebinding in
/// Settings). The AppKit key capture is a thin shell (`App/Settings/HotkeysPane.swift`,
/// verified by running the app); this is the one rule that shell must honor: **at
/// least one modifier is required**, so a captured bare key can never hijack normal
/// typing app-wide once bound (mirrors the Dangerous-Command Scanner's "never weaken
/// a safety guard" posture, applied here to keyboard capture).
public enum HotkeyChordValidation {

    /// Whether `modifiers` is a legal set for a new binding — non-empty.
    public static func isValid(modifiers: Set<Settings.HotkeyModifier>) -> Bool {
        !modifiers.isEmpty
    }

    /// Build a `Settings.HotkeyBinding` from a captured `(keyCode, modifiers)`, or
    /// `nil` if it fails `isValid` — the caller (the rebind UI) then keeps recording
    /// instead of saving an unusable binding.
    ///
    /// The binding's `modifiers` are emitted in `Settings.HotkeyModifier.allCases`
    /// order regardless of the input `Set`'s iteration order, so re-recording the same
    /// physical chord always produces byte-identical JSON (§2.5's diff-stability goal).
    public static func makeBinding(
        keyCode: Int,
        modifiers: Set<Settings.HotkeyModifier>,
        mode: Settings.HotkeyMode = .pushToTalk
    ) -> Settings.HotkeyBinding? {
        guard isValid(modifiers: modifiers) else { return nil }
        let ordered = Settings.HotkeyModifier.allCases.filter { modifiers.contains($0) }
        return Settings.HotkeyBinding(keyCode: keyCode, modifiers: ordered, mode: mode)
    }
}
