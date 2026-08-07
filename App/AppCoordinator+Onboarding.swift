import Configuration
import Foundation
import Onboarding
import Permissions

/// `AppCoordinator`'s first-run onboarding flow (PHASE 10; User Stories 16–24),
/// split out of the coordinator's primary declaration so no single file/type grows
/// unwieldy. It presents/advances the pure `OnboardingFlow`, persists progress so the
/// walkthrough is resumable, and drives prompt-free permission auto-advance.
extension AppCoordinator {

    /// Build the flow at the persisted resume point (fresh `.welcome` on a genuine
    /// first run) and show the onboarding window, unless a prior launch already
    /// finished it. Called once, right after settings load.
    func setUpOnboarding() {
        guard !settings.onboarding.completed else { return }
        let persistedStep = OnboardingStep(rawValue: settings.onboarding.resumeStep) ?? .welcome
        // Clamp the persisted resume point so a stale value (e.g. one saved before the
        // Input Monitoring step existed) can never jump the flow PAST an ungranted
        // required permission — otherwise the user never sees that permission's grant
        // screen. See `OnboardingFlow.safeResumeStep`.
        let resumeStep = OnboardingFlow.safeResumeStep(persisted: persistedStep) {
            permissionGate.status(for: $0) == .granted
        }
        onboardingFlow = OnboardingFlow(
            resumeAt: resumeStep, disclosureAcknowledged: settings.privacy.networkUtilitiesDisclosed)
        syncOnboardingProgress()
        onboardingWindow.show(coordinator: self)
    }

    /// Advance from a step that needs no external gate — `.welcome`, `.tier`,
    /// `.hotkeys`, `.firstSuccess`, `.summary`. A no-op if the current step is
    /// gated (a permission step or `.disclosure`) or onboarding isn't active.
    func onboardingAdvance() {
        guard onboardingFlow?.advance() == true else { return }
        syncOnboardingProgress()
    }

    /// Skip the current step — legal only for the optional Calendar permission step
    /// (User Story 21).
    func onboardingSkip() {
        guard onboardingFlow?.skip() == true else { return }
        syncOnboardingProgress()
    }

    /// Explicitly proceed past the current permission step without an observed grant —
    /// legal only when that permission's grant can't be verified in-session (macOS never
    /// reflects a fresh Screen Recording grant until Aide relaunches; see
    /// `Permission.grantTakesEffectAfterRelaunch`). A no-op for every other permission
    /// step, so Microphone/Accessibility/Calendar are untouched — they still only advance
    /// via an observed grant (or, for Calendar, `onboardingSkip()`).
    func onboardingProceedPastRelaunchGatedPermission() {
        guard onboardingFlow?.proceedPastRelaunchGatedPermission() == true else { return }
        syncOnboardingProgress()
    }

    /// Acknowledge the one-time keyless-utility-calls disclosure (User Story 22),
    /// persisting the ack immediately so it can never show again on a later launch.
    func onboardingAcknowledgeDisclosure() {
        guard onboardingFlow?.acknowledgeDisclosure() == true else { return }
        updateSettings { $0.privacy.networkUtilitiesDisclosed = true }
        syncOnboardingProgress()
    }

    /// Poll the current onboarding permission step's grant status **prompt-free**
    /// and auto-advance if it's now granted (User Story 20). Called on a light
    /// timer while a permission step is showing, immediately when the app regains
    /// focus (`applicationDidBecomeActive`, below — the user returning from System
    /// Settings), and by each permission step's own "Re-check" affordance.
    func recheckOnboardingPermission() {
        guard let permission = onboardingFlow?.currentStep?.permission else { return }
        let status = permissionGate.status(for: permission)
        // Input Monitoring: try to (re)install the event tap now, then gate the advance on whether
        // it ACTUALLY installed — macOS can report the permission granted while tap creation is
        // still denied (e.g. a stale grant after a dev rebuild), and advancing on that false
        // proxy hard-blocks the user at the "Try It" step with a dead hotkey. On a fresh first
        // run `startHotkeys()` installs the tap before Input Monitoring is granted, so it fails
        // silently; reusing this recovery path is also what brings the global hotkey alive
        // without waiting on the unrelated menubar fix-it's "Re-check" button.
        if permission == .inputMonitoring {
            recheckInputMonitoring()
        }
        let tapInstalled = hotkeys.isTapInstalled
        guard onboardingFlow?.advance(afterObserving: status, for: permission, hotkeyTapInstalled: tapInstalled) == true
        else { return }
        syncOnboardingProgress()
    }

    /// Trigger the current permission step's **native grant prompt** in-app (User Story 18;
    /// LLD §8 "Prompt" column) for permissions Aide can request — Microphone, Screen
    /// Recording, Calendar — then re-check + auto-advance on the user's response. macOS only
    /// lists those under System Settings → Privacy *after* a first request, so this is what
    /// makes the grant reachable at all (Accessibility has no in-app prompt — the step
    /// deep-links instead). `then` lets the step refresh its own affordance after a decline
    /// (so it flips from "Allow…" to the Settings deep-link).
    func requestOnboardingPermission(then refresh: @escaping () -> Void = {}) {
        guard let permission = onboardingFlow?.currentStep?.permission else { return }
        SystemPermissionRequester().request(permission) { [weak self] in
            self?.recheckOnboardingPermission()
            refresh()
        }
    }

    /// Forwarded from `AppDelegate.applicationDidBecomeActive(_:)` — the moment the
    /// user switches back to Aide, which is exactly when they'd be returning from
    /// granting a permission in System Settings (User Story 20).
    func applicationDidBecomeActive() {
        recheckOnboardingPermission()
    }

    /// After any successful flow transition: mark onboarding complete (and tear
    /// down its window/polling) once the flow reports `isComplete`; otherwise
    /// persist the new resume step and keep the permission-poll timer in step with
    /// whether the *new* current step is a permission step.
    private func syncOnboardingProgress() {
        guard let flow = onboardingFlow else { return }
        if flow.isComplete {
            completeOnboarding()
            return
        }
        if let step = flow.currentStep, step.rawValue != settings.onboarding.resumeStep {
            updateSettings { $0.onboarding.resumeStep = step.rawValue }
        }
        refreshOnboardingPermissionPolling()
    }

    /// Persist completion, dismiss the window, and stop polling — onboarding is
    /// done for good (User Stories 16–24's acceptance demo: the walkthrough never
    /// reappears once finished).
    private func completeOnboarding() {
        updateSettings { $0.onboarding.completed = true }
        stopOnboardingPermissionPolling()
        onboardingWindow.dismiss()
        onboardingFlow = nil
    }

    /// Start/stop the light poll timer to match whether onboarding is currently
    /// sitting on a permission step — no timer runs otherwise (near-zero idle cost
    /// the rest of the flow, matching the app's low-idle-CPU posture).
    private func refreshOnboardingPermissionPolling() {
        guard onboardingFlow?.currentStep?.permission != nil else {
            stopOnboardingPermissionPolling()
            return
        }
        onboardingPermissionPollTimer?.invalidate()
        onboardingPermissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recheckOnboardingPermission() }
        }
    }

    private func stopOnboardingPermissionPolling() {
        onboardingPermissionPollTimer?.invalidate()
        onboardingPermissionPollTimer = nil
    }
}
