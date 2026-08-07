import XCTest

@testable import Permissions

/// Behaviour spec for the `Permissions` deep module (P1 Phase 7; User Stories 25, 26, 27).
///
/// Everything here is exercised through the module's public interface with **injected**
/// statuses — no live TCC query, no system prompt — so the suite is deterministic and
/// headless (mirrors the `DangerousCommandScanner` pattern). The two things under test:
/// (a) status → fix-it hint + System Settings deep-link mapping, and (b) the per-permission
/// degradation map (a denied permission disables *exactly* its dependent features).
final class PermissionGateTests: XCTestCase {

    // MARK: - Deep-links (LLD §8: exact System Settings pane per permission)

    func testDeepLinksHitTheExactSettingsPane() {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        XCTAssertEqual(Permission.microphone.settingsDeepLink.absoluteString, "\(base)?Privacy_Microphone")
        XCTAssertEqual(
            Permission.accessibility.settingsDeepLink.absoluteString, "\(base)?Privacy_Accessibility")
        XCTAssertEqual(
            Permission.inputMonitoring.settingsDeepLink.absoluteString, "\(base)?Privacy_ListenEvent")
        XCTAssertEqual(
            Permission.screenRecording.settingsDeepLink.absoluteString, "\(base)?Privacy_ScreenCapture")
        XCTAssertEqual(Permission.calendar.settingsDeepLink.absoluteString, "\(base)?Privacy_Calendars")
    }

    // MARK: - Optionality (LLD §8: Calendar is optional / skippable)

    func testOnlyCalendarIsOptional() {
        XCTAssertTrue(Permission.calendar.isOptional)
        for permission in [Permission.microphone, .accessibility, .inputMonitoring, .screenRecording] {
            XCTAssertFalse(permission.isOptional, "\(permission) is required, not optional")
        }
    }

    // MARK: - Relaunch-gated grants (Screen Recording only — macOS grant-visibility bug)

    func testOnlyScreenRecordingRequiresARelaunchToObserveItsGrant() {
        XCTAssertTrue(Permission.screenRecording.grantTakesEffectAfterRelaunch)
        for permission in [Permission.microphone, .accessibility, .inputMonitoring, .calendar] {
            XCTAssertFalse(
                permission.grantTakesEffectAfterRelaunch,
                "\(permission)'s grant is observable in-session and must not be relaunch-gated")
        }
    }

    // MARK: - Degradation map (LLD §8: which features each permission gates)

    func testDegradationMapMatchesTheLLDTable() {
        XCTAssertEqual(Permission.microphone.gatedFeatures, [.commandMode, .dictationMode, .wakeWord])
        XCTAssertEqual(Permission.accessibility.gatedFeatures, [.textInsertion])
        XCTAssertEqual(Permission.inputMonitoring.gatedFeatures, [.hotkeyCapture])
        XCTAssertEqual(Permission.screenRecording.gatedFeatures, [.screenQA])
        XCTAssertEqual(Permission.calendar.gatedFeatures, [.calendarSkill])
    }

    /// Every feature is gated by exactly one permission (a clean partition), so
    /// "disables exactly its dependents and nothing else" is well-defined.
    func testEveryFeatureIsGatedByExactlyOnePermission() {
        for feature in Feature.allCases {
            let owners = Permission.allCases.filter { $0.gatedFeatures.contains(feature) }
            XCTAssertEqual(owners, [feature.requiredPermission], "\(feature) must have one gating permission")
        }
        // The gated sets cover all features with no overlap.
        let union = Permission.allCases.reduce(into: Set<Feature>()) { $0.formUnion($1.gatedFeatures) }
        XCTAssertEqual(union, Set(Feature.allCases))
    }

    // MARK: - Status → fix-it advice mapping

    func testGrantedPermissionsHaveNoFixIt() {
        for permission in Permission.allCases {
            XCTAssertNil(
                PermissionAdvice.make(for: permission, status: .granted),
                "a granted permission needs no fix-it")
        }
    }

    func testDeniedPermissionYieldsHintAndMatchingDeepLink() {
        for permission in Permission.allCases {
            guard let advice = PermissionAdvice.make(for: permission, status: .denied) else {
                return XCTFail("\(permission) denied must produce a fix-it")
            }
            XCTAssertFalse(advice.hint.isEmpty, "the fix-it hint must be actionable, not empty")
            XCTAssertEqual(advice.deepLink, permission.settingsDeepLink, "fix-it must deep-link to the exact pane")
            XCTAssertEqual(advice.permission, permission)
        }
    }

    func testNotDeterminedAlsoYieldsAFixIt() {
        for permission in Permission.allCases {
            XCTAssertNotNil(
                PermissionAdvice.make(for: permission, status: .notDetermined),
                "\(permission) not-yet-granted must still surface a fix-it so the user can grant it")
        }
    }

    func testRestrictedHintDiffersFromDenied() {
        // A system-policy (MDM / Screen Time) restriction is not user-fixable the same
        // way; the hint must say so rather than repeat "just turn it on".
        let denied = PermissionAdvice.make(for: .microphone, status: .denied)
        let restricted = PermissionAdvice.make(for: .microphone, status: .restricted)
        XCTAssertNotNil(restricted)
        XCTAssertNotEqual(denied?.hint, restricted?.hint)
    }

    // MARK: - PermissionGate: degradation (the core invariant)

    /// The headline rule (User Story 25): a single denied permission disables **exactly**
    /// its dependent features and nothing else.
    func testOneDeniedPermissionDisablesExactlyItsDependents() {
        for denied in Permission.allCases {
            var statuses = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, PermissionStatus.granted) })
            statuses[denied] = .denied
            let gate = PermissionGate(statuses: statuses)

            XCTAssertEqual(
                gate.disabledFeatures(), denied.gatedFeatures,
                "denying \(denied) must disable exactly its features")

            // Its own features are off…
            for feature in denied.gatedFeatures {
                XCTAssertFalse(gate.isEnabled(feature), "\(feature) depends on the denied \(denied)")
            }
            // …every other feature stays on.
            for feature in Set(Feature.allCases).subtracting(denied.gatedFeatures) {
                XCTAssertTrue(gate.isEnabled(feature), "\(feature) does not depend on \(denied) and must stay enabled")
            }
        }
    }

    func testAllGrantedEnablesEverything() {
        let gate = PermissionGate(
            statuses: Dictionary(
                uniqueKeysWithValues: Permission.allCases.map { ($0, PermissionStatus.granted) }))
        XCTAssertTrue(gate.disabledFeatures().isEmpty)
        XCTAssertTrue(gate.fixIts().isEmpty)
        for feature in Feature.allCases {
            XCTAssertTrue(gate.isEnabled(feature))
        }
    }

    func testAllDeniedDisablesEverythingAndListsEveryFixIt() {
        let gate = PermissionGate(
            statuses: Dictionary(
                uniqueKeysWithValues: Permission.allCases.map { ($0, PermissionStatus.denied) }))
        XCTAssertEqual(gate.disabledFeatures(), Set(Feature.allCases))
        XCTAssertEqual(gate.fixIts().map(\.permission), Permission.allCases)
    }

    func testMissingStatusIsTreatedAsNotGranted() {
        // An unread permission must fail safe (feature disabled) rather than assume granted.
        let gate = PermissionGate(statuses: [:])
        XCTAssertEqual(gate.status(for: .microphone), .notDetermined)
        XCTAssertFalse(gate.isEnabled(.commandMode))
        XCTAssertEqual(gate.disabledFeatures(), Set(Feature.allCases))
    }

    // MARK: - PermissionGate: fix-it surface + recovery

    func testGateAdviceIsNilOnceGranted_RecoveryPath() {
        // Re-granting recovers: the same gate over an updated status yields no fix-it and
        // re-enables the feature (the deterministic core behind the AX menubar recovery).
        var current: PermissionStatus = .denied
        let gate = PermissionGate(read: { permission in
            permission == .accessibility ? current : .granted
        })
        XCTAssertNotNil(gate.advice(for: .accessibility))
        XCTAssertFalse(gate.isEnabled(.textInsertion))

        current = .granted
        XCTAssertNil(gate.advice(for: .accessibility))
        XCTAssertTrue(gate.isEnabled(.textInsertion))
    }

    func testDegradedPermissionsListedInCanonicalOrder() {
        let gate = PermissionGate(statuses: [
            .microphone: .granted,
            .accessibility: .denied,
            .inputMonitoring: .granted,
            .screenRecording: .granted,
            .calendar: .notDetermined,
        ])
        XCTAssertEqual(gate.degradedPermissions(), [.accessibility, .calendar])
    }
}
