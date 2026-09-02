import XCTest

@testable import CommandRouter

/// Pins the LLD §4.2 provisional literals to the single source of truth.
/// Other suites must compare against `.provisional` properties, never these numbers.
final class RoutingThresholdsTests: XCTestCase {

    func testProvisionalMatchesLLDSection42() {
        XCTAssertEqual(RoutingThresholds.provisional.routeHigh, -0.15)
        XCTAssertEqual(RoutingThresholds.provisional.routeLow, -0.7)
    }
}
