import LLMRuntime
import XCTest

@testable import Dictation

final class SidecarReadinessPolicyTests: XCTestCase {

    func testReadyProceeds() {
        let decision = SidecarReadinessPolicy.decide(.ready)
        XCTAssertEqual(decision, .proceed)
    }

    func testLaunchingWaitsForTheLaunchDeadline() {
        let decision = SidecarReadinessPolicy.decide(.launching)
        XCTAssertEqual(decision, .waitUpTo(SidecarReadinessPolicy.launchWaitDeadline))
    }

    func testUnavailableInsertsRaw() {
        let decision = SidecarReadinessPolicy.decide(.unavailable)
        XCTAssertEqual(decision, .insertRaw)
    }

    func testLaunchWaitDeadlineIsTwoSeconds() {
        XCTAssertEqual(SidecarReadinessPolicy.launchWaitDeadline, 2)
    }

    func testReadinessForStoppedStateIsUnavailable() {
        XCTAssertEqual(SidecarReadinessPolicy.readiness(for: .stopped), .unavailable)
    }

    func testReadinessForLaunchingStateIsLaunching() {
        XCTAssertEqual(SidecarReadinessPolicy.readiness(for: .launching), .launching)
    }

    func testReadinessForReadyStateIsReady() {
        XCTAssertEqual(SidecarReadinessPolicy.readiness(for: .ready(port: 8080)), .ready)
    }

    func testReadinessForUnhealthyStateIsUnavailable() {
        XCTAssertEqual(SidecarReadinessPolicy.readiness(for: .unhealthy(retryIn: 4)), .unavailable)
    }

    func testReadinessForFailedStateIsUnavailable() {
        XCTAssertEqual(SidecarReadinessPolicy.readiness(for: .failed(reason: "max retries exceeded")), .unavailable)
    }
}
