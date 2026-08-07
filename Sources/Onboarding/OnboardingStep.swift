import Permissions

/// The ordered first-run walkthrough steps (Phase 10; User Stories 16–24;
/// docs/04-hld.md §14's locked ordering). Declaration order **is** the flow order:
/// welcome + privacy promise → RAM detection / Tier confirm-or-override → one step
/// per permission (mirroring `Permission.allCases`: microphone → accessibility →
/// input monitoring → screen recording → calendar) → the one-time keyless-utility-calls disclosure →
/// hotkey setup → guided first success → the graceful-degradation summary.
///
/// `OnboardingFlow` is the pure state machine that walks this order; this type owns
/// only the ordering + the step→permission mapping.
public enum OnboardingStep: String, CaseIterable, Sendable, Equatable, Codable {
    case welcome
    case tier
    case permissionMicrophone = "permission_microphone"
    case permissionAccessibility = "permission_accessibility"
    case permissionInputMonitoring = "permission_input_monitoring"
    case permissionScreenRecording = "permission_screen_recording"
    case permissionCalendar = "permission_calendar"
    case disclosure
    case hotkeys
    case firstSuccess = "first_success"
    case summary

    /// The permission a permission step gates, or `nil` for every non-permission
    /// step. The five permission cases map onto `Permission.allCases`, in the same
    /// order (`OnboardingFlowTests.testPermissionStepsMapOntoPermissionAllCasesInOrder`).
    public var permission: Permission? {
        switch self {
        case .permissionMicrophone: return .microphone
        case .permissionAccessibility: return .accessibility
        case .permissionInputMonitoring: return .inputMonitoring
        case .permissionScreenRecording: return .screenRecording
        case .permissionCalendar: return .calendar
        case .welcome, .tier, .disclosure, .hotkeys, .firstSuccess, .summary: return nil
        }
    }

    /// The step immediately after this one in the locked order, or `nil` if this is
    /// the last step (`.summary`) — `nil` is `OnboardingFlow`'s "flow complete" signal.
    var next: OnboardingStep? {
        guard let index = Self.allCases.firstIndex(of: self) else { return nil }
        let nextIndex = Self.allCases.index(after: index)
        return nextIndex < Self.allCases.endIndex ? Self.allCases[nextIndex] : nil
    }
}
