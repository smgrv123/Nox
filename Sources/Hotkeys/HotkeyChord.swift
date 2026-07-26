import Configuration
import CoreGraphics

/// A resolved hotkey **chord**: a base key plus the exact set of modifier keys that
/// must be held with it. This is the internal representation the binder matches events
/// against — it holds a `Set` (not the file's ordered array) so modifier order in
/// `settings.json` is irrelevant, and equality is a pure structural comparison.
public struct HotkeyChord: Equatable, Sendable {

    /// Hardware virtual key code of the base key (e.g. 49 = Space).
    public let keyCode: Int

    /// The modifier keys required alongside `keyCode`.
    public let modifiers: Set<Settings.HotkeyModifier>

    public init(keyCode: Int, modifiers: Set<Settings.HotkeyModifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Build the chord for a stored binding (the "settings → chord" mapping).
    public init(_ binding: Settings.HotkeyBinding) {
        self.keyCode = binding.keyCode
        self.modifiers = Set(binding.modifiers)
    }
}

extension Settings.HotkeyModifier {

    /// This modifier's bit in a `CGEventFlags` value (docs/05-lld.md §8). Kept next to
    /// the enum so the raw-event mapping lives in one place; using the framework
    /// constants (rather than magic hex) keeps it correct-by-construction.
    var cgEventFlagMask: UInt64 {
        switch self {
        case .command: return CGEventFlags.maskCommand.rawValue
        case .control: return CGEventFlags.maskControl.rawValue
        case .option: return CGEventFlags.maskAlternate.rawValue
        case .shift: return CGEventFlags.maskShift.rawValue
        }
    }

    /// Extract just the **chord-relevant** modifiers from a raw `CGEventFlags` value.
    ///
    /// The event tap reports many flag bits — Caps Lock (`maskAlphaShift`), Fn
    /// (`maskSecondaryFn`), numeric-pad, etc. — that must not affect a chord match; we
    /// look only at the four modifiers a hotkey can bind. This is the finicky, pure
    /// heart of turning an OS event into something the binder can compare.
    public static func set(fromEventFlags rawFlags: UInt64) -> Set<Settings.HotkeyModifier> {
        Set(allCases.filter { rawFlags & $0.cgEventFlagMask != 0 })
    }
}
