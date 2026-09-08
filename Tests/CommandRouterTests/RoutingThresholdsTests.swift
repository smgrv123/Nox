import XCTest

@testable import CommandRouter

/// Pins the provisional literals to the single source of truth. Other suites
/// must compare against `.provisional` properties, never these numbers.
///
/// NOTE: these values supersede the stale docs/05-lld.md §4.2 example
/// (`routeHigh: -0.15, routeLow: -0.7`), which was calibrated against
/// synthetic logprobs. A sample of real per-token routing-logprob means
/// ranged -0.72 to -5.08 across utterances — below the old `routeLow`
/// entirely — so the thresholds were recalibrated to bracket that measured
/// range. See the doc comment on `RoutingThresholds.provisional`.
final class RoutingThresholdsTests: XCTestCase {

    func testProvisionalMatchesRecalibratedRealModelRange() {
        XCTAssertEqual(RoutingThresholds.provisional.routeHigh, -1.2)
        XCTAssertEqual(RoutingThresholds.provisional.routeLow, -4.5)
    }
}
