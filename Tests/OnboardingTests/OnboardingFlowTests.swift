import Permissions
import XCTest

@testable import Onboarding

/// Phase 10's pure first-run flow coordinator (specs/P1 §"Onboarding"; User Stories
/// 16–24). TDD per specs/P1 §"Testing Decisions": permission statuses and the
/// resume/disclosure state are injected — no live TCC, no `Date()` — so every
/// advancement rule is exercised deterministically, mirroring how
/// `OverlayStateMachineTests` pins down `OverlayStateMachine`.
final class OnboardingFlowTests: XCTestCase {

    // MARK: - Full ordered traversal from a cleared state

    func testFreshFlowWalksEveryStepInOrder() {
        var flow = OnboardingFlow()
        XCTAssertEqual(flow.currentStep, .welcome)

        XCTAssertTrue(flow.advance())
        XCTAssertEqual(flow.currentStep, .tier)

        XCTAssertTrue(flow.advance())
        XCTAssertEqual(flow.currentStep, .permissionMicrophone)

        XCTAssertTrue(flow.advance(afterObserving: .granted, for: .microphone))
        XCTAssertEqual(flow.currentStep, .permissionAccessibility)

        XCTAssertTrue(flow.advance(afterObserving: .granted, for: .accessibility))
        XCTAssertEqual(flow.currentStep, .permissionInputMonitoring)

        XCTAssertTrue(flow.advance(afterObserving: .granted, for: .inputMonitoring, hotkeyTapInstalled: true))
        XCTAssertEqual(flow.currentStep, .permissionScreenRecording)

        XCTAssertTrue(flow.advance(afterObserving: .granted, for: .screenRecording))
        XCTAssertEqual(flow.currentStep, .permissionCalendar)

        XCTAssertTrue(flow.advance(afterObserving: .granted, for: .calendar))
        XCTAssertEqual(flow.currentStep, .disclosure)

        XCTAssertTrue(flow.acknowledgeDisclosure())
        XCTAssertEqual(flow.currentStep, .hotkeys)

        XCTAssertTrue(flow.advance())
        XCTAssertEqual(flow.currentStep, .firstSuccess)

        XCTAssertTrue(flow.advance())
        XCTAssertEqual(flow.currentStep, .summary)
        XCTAssertFalse(flow.isComplete)

        XCTAssertTrue(flow.advance())
        XCTAssertNil(flow.currentStep)
        XCTAssertTrue(flow.isComplete)
    }

    func testOrderedStepsMatchTheLockedPlan() {
        // docs/04-hld.md §14's locked ordering, mirrored 1:1 into `CaseIterable`
        // declaration order — the property `OnboardingFlow` walks.
        XCTAssertEqual(
            OnboardingStep.allCases,
            [
                .welcome, .tier,
                .permissionMicrophone, .permissionAccessibility, .permissionInputMonitoring,
                .permissionScreenRecording, .permissionCalendar,
                .disclosure, .hotkeys, .firstSuccess, .summary,
            ])
    }

    // MARK: - Auto-advance on an injected grant event (User Story 20)

    func testGrantEventForADifferentPermissionDoesNotAdvance() {
        var flow = OnboardingFlow(resumeAt: .permissionMicrophone)
        XCTAssertFalse(flow.advance(afterObserving: .granted, for: .accessibility))
        XCTAssertEqual(flow.currentStep, .permissionMicrophone)
    }

    func testNonGrantedStatusesDoNotAdvance() {
        for status: PermissionStatus in [.denied, .notDetermined, .restricted] {
            var flow = OnboardingFlow(resumeAt: .permissionMicrophone)
            XCTAssertFalse(flow.advance(afterObserving: status, for: .microphone), "\(status) must not auto-advance")
            XCTAssertEqual(flow.currentStep, .permissionMicrophone)
        }
    }

    func testGrantEventOutsideAPermissionStepIsANoOp() {
        var flow = OnboardingFlow(resumeAt: .welcome)
        XCTAssertFalse(flow.advance(afterObserving: .granted, for: .microphone))
        XCTAssertEqual(flow.currentStep, .welcome)
    }

    func testPlainAdvanceIsRejectedOnAPermissionStep() {
        // A permission step's only legal advancement is a grant event or (if
        // optional) a skip — never the unconditional `advance()`.
        var flow = OnboardingFlow(resumeAt: .permissionMicrophone)
        XCTAssertFalse(flow.advance())
        XCTAssertEqual(flow.currentStep, .permissionMicrophone)
    }

    // MARK: - Input Monitoring advance is gated on the hotkey tap actually installing
    //
    // macOS can report Input Monitoring `.granted` (`IOHIDCheckAccess() == granted`) while the
    // global hotkey event tap still FAILS to install (stale-grant / cdhash mismatch on dev
    // builds). Advancing off the Input Monitoring step on that false proxy hard-blocks the user
    // later at "Try It" with a dead hotkey, so the step only advances when the App layer
    // confirms the tap is genuinely installed.

    func testInputMonitoringStepDoesNotAdvanceWhenHotkeyTapNotInstalled() {
        var flow = OnboardingFlow(resumeAt: .permissionInputMonitoring)
        XCTAssertFalse(flow.advance(afterObserving: .granted, for: .inputMonitoring, hotkeyTapInstalled: false))
        XCTAssertEqual(flow.currentStep, .permissionInputMonitoring)
    }

    func testInputMonitoringStepAdvancesWhenGrantedAndHotkeyTapInstalled() {
        var flow = OnboardingFlow(resumeAt: .permissionInputMonitoring)
        XCTAssertTrue(flow.advance(afterObserving: .granted, for: .inputMonitoring, hotkeyTapInstalled: true))
        XCTAssertEqual(flow.currentStep, .permissionScreenRecording)
    }

    func testHotkeyTapGateIsIgnoredForNonInputMonitoringPermissions() {
        // The tap gate applies to Input Monitoring only; every other permission ignores it —
        // e.g. Accessibility advances on an observed grant alone, even with the tap uninstalled.
        var flow = OnboardingFlow(resumeAt: .permissionAccessibility)
        XCTAssertTrue(flow.advance(afterObserving: .granted, for: .accessibility, hotkeyTapInstalled: false))
        XCTAssertEqual(flow.currentStep, .permissionInputMonitoring)
    }

    // MARK: - Skip (Calendar only — User Story 21)

    func testOptionalCalendarStepCanBeSkipped() {
        var flow = OnboardingFlow(resumeAt: .permissionCalendar)
        XCTAssertTrue(flow.skip())
        XCTAssertEqual(flow.currentStep, .disclosure)
    }

    func testRequiredPermissionStepsCannotBeSkipped() {
        for step: OnboardingStep in [
            .permissionMicrophone, .permissionAccessibility, .permissionInputMonitoring, .permissionScreenRecording,
        ] {
            var flow = OnboardingFlow(resumeAt: step)
            XCTAssertFalse(flow.skip(), "\(step) is required and must not be skippable")
            XCTAssertEqual(flow.currentStep, step)
        }
    }

    func testNonPermissionStepsCannotBeSkipped() {
        var flow = OnboardingFlow(resumeAt: .welcome)
        XCTAssertFalse(flow.skip())
        XCTAssertEqual(flow.currentStep, .welcome)
    }

    // MARK: - Explicit proceed past a relaunch-gated permission (Screen Recording only)
    //
    // macOS never reflects a fresh Screen Recording grant within the granting app's own
    // session (`Permission.grantTakesEffectAfterRelaunch`), so the ordinary
    // `advance(afterObserving:for:)` poll can never see `.granted` there. This explicit,
    // user-driven method is the only bypass, and only for that one permission.

    func testRelaunchGatedPermissionStepCanBeExplicitlyProceededPast() {
        var flow = OnboardingFlow(resumeAt: .permissionScreenRecording)
        XCTAssertTrue(flow.proceedPastRelaunchGatedPermission())
        XCTAssertEqual(flow.currentStep, .permissionCalendar)
    }

    func testNonRelaunchGatedRequiredPermissionStepsCannotBeProceededPast() {
        for step: OnboardingStep in [
            .permissionMicrophone, .permissionAccessibility, .permissionInputMonitoring, .permissionCalendar,
        ] {
            var flow = OnboardingFlow(resumeAt: step)
            XCTAssertFalse(
                flow.proceedPastRelaunchGatedPermission(),
                "\(step)'s permission is not relaunch-gated and must not be bypassable")
            XCTAssertEqual(flow.currentStep, step)
        }
    }

    func testProceedPastRelaunchGatedPermissionIsANoOpOutsideAPermissionStep() {
        var flow = OnboardingFlow(resumeAt: .welcome)
        XCTAssertFalse(flow.proceedPastRelaunchGatedPermission())
        XCTAssertEqual(flow.currentStep, .welcome)
    }

    func testSkipStillRejectedOnScreenRecordingDespiteBeingRelaunchGated() {
        // Screen Recording is required, not optional (`isOptional == false`) — `skip()`
        // must still reject it; only the explicit `proceedPastRelaunchGatedPermission()`
        // can move past it. Proves the two mechanisms are independent.
        var flow = OnboardingFlow(resumeAt: .permissionScreenRecording)
        XCTAssertFalse(flow.skip())
        XCTAssertEqual(flow.currentStep, .permissionScreenRecording)
    }

    // MARK: - Resume from a persisted mid-flow step (User Story 24)

    func testResumeInitializesAtThePersistedStep() {
        let flow = OnboardingFlow(resumeAt: .hotkeys)
        XCTAssertEqual(flow.currentStep, .hotkeys)
    }

    func testResumeMidPermissionWalkthroughContinuesFromThatExactPermission() {
        let flow = OnboardingFlow(resumeAt: .permissionScreenRecording)
        XCTAssertEqual(flow.currentStep, .permissionScreenRecording)
        XCTAssertEqual(flow.currentStep?.permission, .screenRecording)
    }

    // MARK: - Disclosure appears exactly once (User Story 22)

    func testDisclosureStepRequiresExplicitAcknowledgement() {
        var flow = OnboardingFlow(resumeAt: .disclosure)
        XCTAssertFalse(flow.advance(), "disclosure must not silently pass via a plain advance")
        XCTAssertEqual(flow.currentStep, .disclosure)

        XCTAssertTrue(flow.acknowledgeDisclosure())
        XCTAssertEqual(flow.currentStep, .hotkeys)
    }

    func testAlreadyAcknowledgedDisclosureIsSkippedOnResume() {
        let flow = OnboardingFlow(resumeAt: .disclosure, disclosureAcknowledged: true)
        XCTAssertEqual(flow.currentStep, .hotkeys, "an already-acknowledged disclosure must never be shown again")
    }

    func testAcknowledgingSetsThePersistedFlag() {
        var flow = OnboardingFlow(resumeAt: .disclosure)
        XCTAssertFalse(flow.disclosureAcknowledged)
        _ = flow.acknowledgeDisclosure()
        XCTAssertTrue(flow.disclosureAcknowledged)
    }

    func testAcknowledgeDisclosureIsANoOpFromAnyOtherStep() {
        var flow = OnboardingFlow(resumeAt: .welcome)
        XCTAssertFalse(flow.acknowledgeDisclosure())
        XCTAssertEqual(flow.currentStep, .welcome)
    }

    // MARK: - Completion

    func testFlowIsNotCompleteUntilAdvancedPastSummary() {
        var flow = OnboardingFlow(resumeAt: .summary)
        XCTAssertFalse(flow.isComplete)
        XCTAssertTrue(flow.advance())
        XCTAssertTrue(flow.isComplete)
        XCTAssertNil(flow.currentStep)
    }

    func testAdvanceOnACompletedFlowIsANoOp() {
        var flow = OnboardingFlow(resumeAt: .summary)
        _ = flow.advance()
        XCTAssertFalse(flow.advance())
        XCTAssertTrue(flow.isComplete)
    }

    // MARK: - Clamping a stale resume step past an ungranted required permission
    //
    // A persisted resume step saved before a permission step existed (or before that
    // permission was granted) must never let the flow jump PAST an ungranted REQUIRED
    // permission — the user would never see its grant screen. `safeResumeStep` clamps
    // the resume point back to the earliest ungranted required permission step.

    func testSafeResumeStepKeepsPersistedWhenAllPermissionsGranted() {
        let clamped = OnboardingFlow.safeResumeStep(persisted: .firstSuccess) { _ in true }
        XCTAssertEqual(clamped, .firstSuccess)
    }

    func testSafeResumeStepClampsToAnUngrantedRequiredPermission() {
        let clamped = OnboardingFlow.safeResumeStep(persisted: .firstSuccess) { $0 != .inputMonitoring }
        XCTAssertEqual(clamped, .permissionInputMonitoring)
    }

    func testSafeResumeStepClampsToTheEarliestUngrantedRequiredPermission() {
        // Accessibility precedes Input Monitoring, so even if both were ungranted the
        // earliest one wins; here only Accessibility is ungranted.
        let clamped = OnboardingFlow.safeResumeStep(persisted: .firstSuccess) { $0 != .accessibility }
        XCTAssertEqual(clamped, .permissionAccessibility)
    }

    func testSafeResumeStepLeavesAnEarlyResumeStepUntouched() {
        // Nothing precedes `.welcome`, so it can never be clamped.
        let clamped = OnboardingFlow.safeResumeStep(persisted: .welcome) { _ in false }
        XCTAssertEqual(clamped, .welcome)
    }

    func testSafeResumeStepIgnoresAnUngrantedOptionalPermission() {
        // Calendar is optional (`isOptional`), so its being ungranted must NOT clamp —
        // onboarding is allowed to have passed it via `skip()`.
        let clamped = OnboardingFlow.safeResumeStep(persisted: .firstSuccess) { $0 != .calendar }
        XCTAssertEqual(clamped, .firstSuccess)
    }

    // MARK: - Step → permission mapping

    func testPermissionStepsMapOntoPermissionAllCasesInOrder() {
        let permissionSteps: [OnboardingStep] = [
            .permissionMicrophone, .permissionAccessibility, .permissionInputMonitoring,
            .permissionScreenRecording, .permissionCalendar,
        ]
        XCTAssertEqual(permissionSteps.map { $0.permission }, Permission.allCases)
    }

    func testNonPermissionStepsHaveNoPermission() {
        for step: OnboardingStep in [.welcome, .tier, .disclosure, .hotkeys, .firstSuccess, .summary] {
            XCTAssertNil(step.permission, "\(step) must not be treated as a permission step")
        }
    }
}
