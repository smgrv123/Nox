import XCTest

@testable import Dictation

final class CleanupPromptBuilderTests: XCTestCase {

    func testIncludesRawTranscriptAndTone() {
        let transcript = "um so the meeting is at three"
        let prompt = CleanupPromptBuilder.build(
            tone: .asIs,
            substitutions: "aide -> Aide",
            rawTranscript: transcript)

        XCTAssertTrue(prompt.contains(transcript), "prompt must include the raw transcript")
        XCTAssertTrue(
            prompt.contains(TonePreset.asIs.instruction),
            "prompt must include the tone instruction")
        XCTAssertTrue(prompt.contains("aide -> Aide"))
    }

    func testEmptySubstitutionsRenderNone() {
        let prompt = CleanupPromptBuilder.build(
            tone: .professional,
            substitutions: "",
            rawTranscript: "hello")

        XCTAssertTrue(
            prompt.contains("none."),
            "empty dictionary substitutions must render as 'none.' so the model is not looking at a blank list")
    }
}
