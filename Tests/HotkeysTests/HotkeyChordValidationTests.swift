import Configuration
import XCTest

@testable import Hotkeys

/// The one rule a freshly **captured** chord must satisfy before it becomes a
/// `Settings.HotkeyBinding` (Phase 9; User Story 14 — rebinding): at least one
/// modifier is required, so a bare key can never hijack normal typing app-wide once
/// bound. The AppKit capture itself (`App/Settings/HotkeysPane.swift`) is a thin
/// shell verified by running the app; this pure decision is what's unit-tested here.
final class HotkeyChordValidationTests: XCTestCase {

    // MARK: - isValid

    func testNoModifiersIsInvalid() {
        XCTAssertFalse(HotkeyChordValidation.isValid(modifiers: []))
    }

    func testAnySingleModifierIsValid() {
        for modifier in Settings.HotkeyModifier.allCases {
            XCTAssertTrue(HotkeyChordValidation.isValid(modifiers: [modifier]), "\(modifier) alone should be valid")
        }
    }

    func testMultipleModifiersAreValid() {
        XCTAssertTrue(HotkeyChordValidation.isValid(modifiers: [.command, .shift]))
    }

    // MARK: - makeBinding

    func testMakeBindingReturnsNilWithoutAModifier() {
        XCTAssertNil(HotkeyChordValidation.makeBinding(keyCode: 49, modifiers: []))
    }

    func testMakeBindingBuildsAPushToTalkBindingByDefault() {
        let binding = HotkeyChordValidation.makeBinding(keyCode: 49, modifiers: [.option])
        XCTAssertEqual(binding, Settings.HotkeyBinding(keyCode: 49, modifiers: [.option], mode: .pushToTalk))
    }

    func testMakeBindingOrdersModifiersDeterministically() {
        // Regardless of the input Set's iteration order, the resulting binding's
        // modifiers array must always come out in the same canonical order — so
        // re-recording the same physical chord twice produces byte-identical JSON.
        let fromOneOrder = HotkeyChordValidation.makeBinding(keyCode: 36, modifiers: [.shift, .command])
        let fromOtherOrder = HotkeyChordValidation.makeBinding(keyCode: 36, modifiers: [.command, .shift])

        XCTAssertEqual(fromOneOrder?.modifiers, fromOtherOrder?.modifiers)
        XCTAssertEqual(fromOneOrder?.modifiers, [Settings.HotkeyModifier.command, .shift])
    }

    func testMakeBindingPreservesKeyCode() {
        let binding = HotkeyChordValidation.makeBinding(keyCode: 100, modifiers: [.control])
        XCTAssertEqual(binding?.keyCode, 100)
    }
}
