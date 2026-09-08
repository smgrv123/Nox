import XCTest

@testable import Dictation

final class TonePresetTests: XCTestCase {

    func testAsIsInstructionMentionsPreserveWording() {
        let instruction = TonePreset.asIs.instruction
        XCTAssertTrue(
            instruction.contains("Preserve the user's wording"),
            "as_is must keep the user's wording (LLD §4.6)")
    }
}
