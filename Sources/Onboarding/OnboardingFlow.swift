import Permissions

/// The pure first-run flow coordinator (Phase 10; User Stories 16–24; specs/P1
/// §"Onboarding"; docs/04-hld.md §14). No I/O, no AppKit, no live TCC query, no
/// `Date()` — every input is injected, mirroring `OverlayStateMachine`'s pattern:
///
/// - the resume point and the disclosure acknowledgement are injected at `init`
///   (the App layer reads them from `Configuration.Settings` before constructing a
///   flow — see `AppCoordinator.setUpOnboarding`);
/// - a permission's grant status is injected as an explicit event
///   (`advance(afterObserving:for:)`), fed by the App layer polling the prompt-free
///   `PermissionGate` (on `NSApplication.didBecomeActive` / a light timer) rather
///   than this type ever touching TCC itself.
///
/// A permission step only advances when its permission is observed `.granted`, or —
/// for the optional Calendar step only — is explicitly `skip()`ped. The one-time
/// disclosure step is bypassed automatically, both at `init` and immediately upon
/// arrival via `advance()`, whenever `disclosureAcknowledged` is already `true` — so
/// it can never show twice in one run (User Story 22); persisting that flag so it
/// never shows again on a *later launch* is the App layer's job (it owns
/// `Configuration.Settings`, which this module deliberately does not depend on).
public struct OnboardingFlow: Equatable, Sendable {

    /// The step currently on screen, or `nil` once the user has advanced past
    /// `.summary` — see `isComplete`.
    public private(set) var currentStep: OnboardingStep?

    /// Whether the one-time keyless-utility-calls disclosure has been acknowledged
    /// this run. Starts from the persisted value the caller injects; flips to `true`
    /// the instant `acknowledgeDisclosure()` succeeds.
    public private(set) var disclosureAcknowledged: Bool

    /// - Parameters:
    ///   - step: where to resume — `.welcome` for a fresh first run, or the
    ///     persisted resume step otherwise (User Story 24).
    ///   - disclosureAcknowledged: the persisted disclosure-ack flag.
    public init(resumeAt step: OnboardingStep = .welcome, disclosureAcknowledged: Bool = false) {
        self.currentStep = step
        self.disclosureAcknowledged = disclosureAcknowledged
        skipDisclosureIfAlreadyAcknowledged()
    }

    /// Whether the flow has finished (the user advanced past `.summary`).
    public var isComplete: Bool { currentStep == nil }

    /// Clamp a persisted resume step so it can never bypass an ungranted **required**
    /// permission step (User Story 24's resumability must not defeat the permission
    /// walkthrough). A resume point saved during an earlier build — before a permission
    /// step existed, or before its permission was granted — could otherwise place the
    /// flow *past* that step, so the user never sees its grant screen (e.g. a stale
    /// `.firstSuccess` jumping over Input Monitoring, leaving the hotkey unauthorizable).
    ///
    /// Returns the **earliest** ungranted-required permission step that precedes
    /// `persisted`, or `persisted` unchanged if none does. Optional permissions
    /// (Calendar) never clamp — onboarding is allowed to have `skip()`ped them.
    ///
    /// - Parameter isGranted: whether a given permission is currently granted, injected
    ///   by the App layer (which owns the live `PermissionGate`); this type stays pure.
    public static func safeResumeStep(
        persisted: OnboardingStep,
        isGranted: (Permission) -> Bool
    ) -> OnboardingStep {
        for step in OnboardingStep.allCases {
            if step == persisted { break }
            guard let permission = step.permission, !permission.isOptional, !isGranted(permission) else { continue }
            return step
        }
        return persisted
    }

    /// Advance from a step that needs no external gate — `.welcome`, `.tier`,
    /// `.hotkeys`, `.firstSuccess`, or `.summary` (the last of which completes the
    /// flow). A permission step or `.disclosure` rejects this (`false`): their
    /// advancement is conditional and goes through the dedicated methods below.
    @discardableResult
    public mutating func advance() -> Bool {
        guard let step = currentStep, step.permission == nil, step != .disclosure else { return false }
        moveToNext()
        return true
    }

    /// Feed a freshly observed permission status — the app's poll after the user
    /// returns from System Settings, or an initial check (User Story 20). Advances
    /// only when `permission` is the **current** step's permission and `status` is
    /// `.granted`; a different permission, a non-granted status, or a non-permission
    /// current step are all no-ops.
    ///
    /// - Parameter hotkeyTapInstalled: an extra gate for the **Input Monitoring** step
    ///   only. macOS can report Input Monitoring `.granted` (`IOHIDCheckAccess() == granted`)
    ///   while the global hotkey event tap still failed to install (stale-grant / cdhash
    ///   mismatch on dev builds); advancing on that false proxy hard-blocks the user later
    ///   at "Try It" with a dead hotkey. So the Input Monitoring step advances only when the
    ///   App layer confirms the tap is genuinely installed. Every other permission ignores
    ///   this flag, and its `true` default keeps all non-input-monitoring call sites unchanged.
    @discardableResult
    public mutating func advance(
        afterObserving status: PermissionStatus,
        for permission: Permission,
        hotkeyTapInstalled: Bool = true
    ) -> Bool {
        guard currentStep?.permission == permission, status == .granted else { return false }
        if permission == .inputMonitoring, !hotkeyTapInstalled { return false }
        moveToNext()
        return true
    }

    /// Skip the current step — legal only for an **optional** permission step
    /// (Calendar; User Story 21). A required permission step, or any non-permission
    /// step, rejects this.
    @discardableResult
    public mutating func skip() -> Bool {
        guard let permission = currentStep?.permission, permission.isOptional else { return false }
        moveToNext()
        return true
    }

    /// Explicitly proceed past the current step's permission **without** an observed
    /// grant — legal only when that permission's grant can't be verified in-session
    /// (`Permission.grantTakesEffectAfterRelaunch`; currently Screen Recording only).
    /// This is how a relaunch-gated permission step avoids hard-stalling onboarding: the
    /// ordinary `advance(afterObserving:for:)` poll can never see `.granted` for it until
    /// the app restarts, so the user drives the advancement directly instead. Every other
    /// permission step (required or optional) rejects this — it grants no bypass beyond
    /// the one macOS-imposed case, so Microphone/Accessibility/Calendar still only
    /// advance via an observed grant (or, for Calendar, `skip()`).
    @discardableResult
    public mutating func proceedPastRelaunchGatedPermission() -> Bool {
        guard let permission = currentStep?.permission, permission.grantTakesEffectAfterRelaunch else {
            return false
        }
        moveToNext()
        return true
    }

    /// Acknowledge the one-time disclosure and advance (User Story 22). Legal only
    /// from `.disclosure`.
    @discardableResult
    public mutating func acknowledgeDisclosure() -> Bool {
        guard currentStep == .disclosure else { return false }
        disclosureAcknowledged = true
        moveToNext()
        return true
    }

    /// Move to `currentStep.next`, then re-apply the disclosure-skip rule — covers
    /// landing on `.disclosure` via ordinary advancement, not just via `init`.
    private mutating func moveToNext() {
        currentStep = currentStep?.next
        skipDisclosureIfAlreadyAcknowledged()
    }

    private mutating func skipDisclosureIfAlreadyAcknowledged() {
        if currentStep == .disclosure, disclosureAcknowledged {
            currentStep = OnboardingStep.disclosure.next
        }
    }
}
