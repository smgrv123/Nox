import XCTest

@testable import Personalization

final class TermPairExtractorTests: XCTestCase {

    func testRejectsEmpty() {
        XCTAssertNil(TermPairExtractor.extractExplicit(mishearing: "", correct: "Kubernetes"))
        XCTAssertNil(TermPairExtractor.extractExplicit(mishearing: "cooper", correct: ""))
        XCTAssertNil(TermPairExtractor.extractExplicit(mishearing: "   ", correct: "Kubernetes"))
        XCTAssertNil(TermPairExtractor.extractExplicit(mishearing: "cooper", correct: " \n "))
        XCTAssertNil(TermPairExtractor.extractExplicit(mishearing: "Foo", correct: "foo"))
        XCTAssertNil(TermPairExtractor.extractExplicit(mishearing: "foo", correct: "FOO"))
    }

    func testTrims() {
        let pair = TermPairExtractor.extractExplicit(
            mishearing: "  cooper nettie's  ",
            correct: "\nKubernetes\t")
        XCTAssertEqual(pair?.mishearing, "cooper nettie's")
        XCTAssertEqual(pair?.correctTerm, "Kubernetes")
    }
}
