import Configuration
import XCTest

@testable import Hotkeys

/// The deep, pure hotkey **binding** logic (docs/05-lld.md §2.5, §8): the two things
/// the OS-bound `CGEventTap` shell delegates to and that must be provably correct —
///
/// 1. **settings → chords:** the two `Settings.hotkeys` bindings become internal
///    chords (base key + a modifier *set*, so modifier order in the file is irrelevant);
/// 2. **event → semantic hotkey:** given a raw `(keyCode, modifierFlags, phase)` from
///    the tap, decide which semantic hotkey it is (command vs dictation) and whether
///    it is a push-to-talk **down** or **up** — or none.
///
/// Everything here runs headlessly from injected values (no `CGEventTap`, no OS
/// permission) per specs/P1 §"Testing Decisions" and the Phase-5 TDD requirement.
final class HotkeyBinderTests: XCTestCase {

    // Well-known CGEventFlags bits (docs/05-lld.md §8) used to fabricate raw events.
    private let shiftFlag: UInt64 = 0x0002_0000
    private let controlFlag: UInt64 = 0x0004_0000
    private let optionFlag: UInt64 = 0x0008_0000
    private let commandFlag: UInt64 = 0x0010_0000
    private let capsLockFlag: UInt64 = 0x0001_0000  // maskAlphaShift — must be ignored
    private let fnFlag: UInt64 = 0x0080_0000  // maskSecondaryFn — must be ignored
    private let spaceKey = 49

    // MARK: - (1) settings → chords

    func testDefaultSettingsMapToTheSpecChords() {
        // §2.5 defaults: ⌥Space (command) and ⌃Space (dictation).
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertEqual(binder.command, HotkeyChord(keyCode: spaceKey, modifiers: [.option]))
        XCTAssertEqual(binder.dictation, HotkeyChord(keyCode: spaceKey, modifiers: [.control]))
    }

    func testChordModifiersAreAnOrderInsensitiveSet() {
        // A file listing modifiers in a different order must yield the same chord —
        // the chord holds a Set, not an ordered array.
        let binding = Settings.HotkeyBinding(keyCode: 36, modifiers: [.shift, .command])
        let chord = HotkeyChord(binding)

        XCTAssertEqual(chord, HotkeyChord(keyCode: 36, modifiers: [.command, .shift]))
        XCTAssertEqual(chord.modifiers, [.command, .shift])
    }

    func testCustomSettingsMapToTheirChords() {
        let hotkeys = Settings.Hotkeys(
            commandMode: Settings.HotkeyBinding(keyCode: 100, modifiers: [.command, .shift]),
            dictationMode: Settings.HotkeyBinding(keyCode: 96, modifiers: []))
        let binder = HotkeyBinder(hotkeys: hotkeys)

        XCTAssertEqual(binder.command, HotkeyChord(keyCode: 100, modifiers: [.command, .shift]))
        XCTAssertEqual(binder.dictation, HotkeyChord(keyCode: 96, modifiers: []))
        XCTAssertEqual(binder.chord(for: .command).keyCode, 100)
        XCTAssertEqual(binder.chord(for: .dictation).keyCode, 96)
    }

    // MARK: - (2a) chord → semantic hotkey

    func testExactChordsMatchTheirSemanticHotkey() {
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertEqual(binder.semanticHotkey(forKeyCode: spaceKey, modifiers: [.option]), .command)
        XCTAssertEqual(binder.semanticHotkey(forKeyCode: spaceKey, modifiers: [.control]), .dictation)
    }

    func testCommandAndDictationAreDistinguishedDespiteSharingAKeyCode() {
        // Both defaults use Space (49); only the modifier differs. The two must never
        // be confused (acceptance: "both hotkeys are distinguished").
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertNotEqual(
            binder.semanticHotkey(forKeyCode: spaceKey, modifiers: [.option]),
            binder.semanticHotkey(forKeyCode: spaceKey, modifiers: [.control]))
    }

    func testWrongModifierOrExtraModifierDoesNotMatch() {
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertNil(binder.semanticHotkey(forKeyCode: spaceKey, modifiers: []), "bare Space is not a bound chord")
        XCTAssertNil(binder.semanticHotkey(forKeyCode: spaceKey, modifiers: [.command]), "⌘Space is unbound")
        XCTAssertNil(
            binder.semanticHotkey(forKeyCode: spaceKey, modifiers: [.option, .shift]), "extra modifier breaks the match"
        )
    }

    func testWrongKeyCodeDoesNotMatch() {
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())
        XCTAssertNil(binder.semanticHotkey(forKeyCode: 36, modifiers: [.option]), "⌥Return is not the bound key")
    }

    // MARK: - (2b) raw event → activation (down / up), decoding CGEventFlags

    func testDownAndUpOnTheCommandChordResolveToCommandActivations() {
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertEqual(
            binder.resolve(keyCode: spaceKey, eventFlags: optionFlag, phase: .down),
            HotkeyActivation(hotkey: .command, phase: .down))
        XCTAssertEqual(
            binder.resolve(keyCode: spaceKey, eventFlags: optionFlag, phase: .up),
            HotkeyActivation(hotkey: .command, phase: .up))
    }

    func testControlSpaceResolvesToDictation() {
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertEqual(
            binder.resolve(keyCode: spaceKey, eventFlags: controlFlag, phase: .down),
            HotkeyActivation(hotkey: .dictation, phase: .down))
    }

    func testUnboundEventResolvesToNil() {
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertNil(binder.resolve(keyCode: spaceKey, eventFlags: 0, phase: .down), "bare Space is unbound")
        XCTAssertNil(binder.resolve(keyCode: 36, eventFlags: optionFlag, phase: .down), "⌥Return is unbound")
        XCTAssertNil(
            binder.resolve(keyCode: spaceKey, eventFlags: optionFlag | commandFlag, phase: .down),
            "⌥⌘Space carries an extra modifier")
    }

    func testIrrelevantModifierBitsAreIgnored() {
        // Caps Lock / Fn set flag bits we don't bind on; they must not defeat a match.
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertEqual(
            binder.resolve(keyCode: spaceKey, eventFlags: optionFlag | capsLockFlag | fnFlag, phase: .down),
            HotkeyActivation(hotkey: .command, phase: .down),
            "Caps Lock / Fn bits must be filtered out before matching")
    }

    func testFlagsDecodeToTheExactModifierSet() {
        // The CGEventFlags → modifier-set extraction, isolated.
        XCTAssertEqual(Settings.HotkeyModifier.set(fromEventFlags: 0), [])
        XCTAssertEqual(Settings.HotkeyModifier.set(fromEventFlags: optionFlag), [.option])
        XCTAssertEqual(
            Settings.HotkeyModifier.set(fromEventFlags: commandFlag | shiftFlag | controlFlag),
            [.command, .shift, .control])
        XCTAssertEqual(
            Settings.HotkeyModifier.set(fromEventFlags: capsLockFlag | fnFlag), [], "only chord modifiers are extracted"
        )
    }

    // MARK: - Ambiguous binding (defensive)

    func testWhenBothHotkeysShareAChordCommandWins() {
        // A user could rebind both to the same chord; matching must stay deterministic.
        let same = Settings.HotkeyBinding(keyCode: spaceKey, modifiers: [.option])
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys(commandMode: same, dictationMode: same))

        XCTAssertEqual(binder.semanticHotkey(forKeyCode: spaceKey, modifiers: [.option]), .command)
    }

    // MARK: - (3) full decision, incl. release-edge safety net

    func testReleaseEdgeFallbackEndsHoldWhenTheModifierWasLiftedFirst() {
        // The user released ⌥ a hair before Space; the tap reports a bare-Space keyUp,
        // which the plain chord match (2b above) does not match. The fallback must still
        // end the `.command` hold rather than leave the UI stuck in "Listening…".
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertEqual(
            binder.resolve(keyCode: spaceKey, eventFlags: 0, phase: .up, activeHotkey: .command),
            HotkeyActivation(hotkey: .command, phase: .up))
    }

    func testReleaseEdgeFallbackDoesNotFireOnKeyDown() {
        // The fallback only ever ends a hold; it must never fabricate a down-edge.
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertNil(binder.resolve(keyCode: spaceKey, eventFlags: 0, phase: .down, activeHotkey: .command))
    }

    func testReleaseEdgeFallbackIgnoresAKeyUpForAnUnrelatedKey() {
        // Only a keyUp on the *held* hotkey's own base key qualifies.
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertNil(
            binder.resolve(keyCode: 36, eventFlags: 0, phase: .up, activeHotkey: .command), "⌥Return, not Space")
    }

    func testReleaseEdgeFallbackDoesNothingWithoutAHeldHotkey() {
        // No hold in progress ⇒ nothing to safety-net.
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertNil(binder.resolve(keyCode: spaceKey, eventFlags: 0, phase: .up, activeHotkey: nil))
    }

    func testNormalMatchTakesPrecedenceOverTheReleaseEdgeFallback() {
        // `activeHotkey` is `.dictation`, but this keyUp's own modifiers now exactly
        // match `.command`'s chord (⌥Space). The plain match must win: the event is
        // reported as ending `.command`, not falsely extending the `.dictation` hold.
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertEqual(
            binder.resolve(keyCode: spaceKey, eventFlags: optionFlag, phase: .up, activeHotkey: .dictation),
            HotkeyActivation(hotkey: .command, phase: .up))
    }

    // MARK: - (4) active-tap consume decision
    //
    // `App/HotkeyManager` now installs an active (`.defaultTap`) tap and must decide,
    // synchronously and per event, whether to swallow it (`return nil` from the tap
    // callback) so the focused app never sees a bound push-to-talk chord — matching
    // Raycast / Wispr Flow. The consume condition IS `resolve(...) != nil`: the exact
    // same call the shell already uses to signal a PTT down/up, reused as-is.

    func testBoundChordKeyDownResolvesSoTheTapWillConsumeIt() {
        // A key-repeat/autorepeat keyDown carries the same (keyCode, flags) as the
        // first press, so it resolves identically — every repeat must be swallowed,
        // not just the initial keyDown, or the app would see the chord mid-hold.
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertNotNil(
            binder.resolve(keyCode: spaceKey, eventFlags: optionFlag, phase: .down, activeHotkey: nil),
            "a bound chord's keyDown (incl. autorepeat) must resolve so the tap swallows it")
    }

    func testUnboundKeyDownResolvesToNilSoTheTapPassesItThrough() {
        let binder = HotkeyBinder(hotkeys: Settings.Hotkeys())

        XCTAssertNil(
            binder.resolve(keyCode: spaceKey, eventFlags: 0, phase: .down, activeHotkey: nil),
            "an unbound key must resolve to nil so the tap leaves it untouched")
    }
}
