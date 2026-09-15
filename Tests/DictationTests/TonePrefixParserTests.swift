import XCTest

@testable import Dictation

final class TonePrefixParserTests: XCTestCase {

    func testProfessionalTonePrefix() {
        let parsed = TonePrefixParser().parse("professional tone: hello world")
        XCTAssertEqual(parsed.preset, .professional)
        XCTAssertEqual(parsed.remainder, "hello world")
    }

    func testPrefixIsCaseInsensitive() {
        let parsed = TonePrefixParser().parse("PROFESSIONAL TONE: Hello there")
        XCTAssertEqual(parsed.preset, .professional)
        XCTAssertEqual(parsed.remainder, "Hello there")
    }

    func testMidSentenceToneIsIgnored() {
        let transcript = "please use a professional tone: thanks"
        let parsed = TonePrefixParser().parse(transcript)
        XCTAssertNil(parsed.preset)
        XCTAssertEqual(parsed.remainder, transcript)
    }
}
