import XCTest

@testable import Permissions

/// `Permission.canRequestInApp` — which permissions onboarding grants via a native in-app
/// prompt vs. a System Settings deep-link (docs/05-lld.md §8). Accessibility cannot be
/// prompted programmatically; the other three must be requested (they aren't listed under
/// System Settings → Privacy until Aide has requested once).
final class PermissionRequestabilityTests: XCTestCase {

    func testMicrophoneScreenRecordingAndCalendarAreRequestableInApp() {
        XCTAssertTrue(Permission.microphone.canRequestInApp)
        XCTAssertTrue(Permission.inputMonitoring.canRequestInApp)
        XCTAssertTrue(Permission.screenRecording.canRequestInApp)
        XCTAssertTrue(Permission.calendar.canRequestInApp)
    }

    func testAccessibilityIsNotRequestableInApp() {
        XCTAssertFalse(Permission.accessibility.canRequestInApp)
    }

    // MARK: - `offersInAppRequest(at:)` — onboarding's request-vs-deep-link decision

    /// Microphone/Calendar report genuine `.notDetermined`; requesting again after an
    /// explicit denial silently no-ops, so the in-app prompt is only offered pre-decision.
    func testMicrophoneAndCalendarOfferTheRequestOnlyWhenNotDetermined() {
        for permission in [Permission.microphone, .inputMonitoring, .calendar] {
            XCTAssertTrue(permission.offersInAppRequest(at: .notDetermined))
            XCTAssertFalse(permission.offersInAppRequest(at: .denied))
            XCTAssertFalse(permission.offersInAppRequest(at: .restricted))
            XCTAssertFalse(permission.offersInAppRequest(at: .granted))
        }
    }

    /// Accessibility has no in-app prompt at all (`canRequestInApp == false`), regardless
    /// of status.
    func testAccessibilityNeverOffersTheRequest() {
        for status in PermissionStatus.allCases {
            XCTAssertFalse(Permission.accessibility.offersInAppRequest(at: status))
        }
    }

    /// Screen Recording's status is read via `CGPreflightScreenCaptureAccess()` — a bare
    /// `Bool` — so it can never actually be `.notDetermined` in practice, but the decision
    /// must still hold for every status the type can represent: offer the request (it's
    /// also the registration step) whenever the permission isn't already granted.
    func testScreenRecordingOffersTheRequestUntilGranted() {
        XCTAssertTrue(Permission.screenRecording.offersInAppRequest(at: .notDetermined))
        XCTAssertTrue(Permission.screenRecording.offersInAppRequest(at: .denied))
        XCTAssertTrue(Permission.screenRecording.offersInAppRequest(at: .restricted))
        XCTAssertFalse(Permission.screenRecording.offersInAppRequest(at: .granted))
    }
}
