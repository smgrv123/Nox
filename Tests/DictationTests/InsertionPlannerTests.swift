import XCTest

@testable import Dictation

final class InsertionPlannerTests: XCTestCase {

    private let planner = InsertionPlanner()
    private let focus = InsertionFocus(bundleID: "com.apple.TextEdit", accessibilityTrusted: true)

    func testDefaultPlanIsAXThenPaste() {
        let plan = planner.plan(focus: focus, override: nil, isTerminal: false)
        XCTAssertEqual(plan, .axThenPaste)
    }

    func testPasteOverride() {
        let plan = planner.plan(focus: focus, override: .paste, isTerminal: false)
        XCTAssertEqual(plan, .pasteOnly)
    }

    func testAXOverride() {
        let plan = planner.plan(focus: focus, override: .ax, isTerminal: false)
        XCTAssertEqual(plan, .axOnly)
    }
}
