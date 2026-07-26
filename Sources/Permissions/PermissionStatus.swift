import Foundation

/// A permission's grant state as read **prompt-free** (User Story 27). Mirrors the
/// shape of the underlying TCC status enums (`AVAuthorizationStatus`,
/// `EKAuthorizationStatus`, and the boolean AX / Screen-Recording preflights, which the
/// effectful shell maps into `.granted` / `.denied`).
public enum PermissionStatus: String, CaseIterable, Sendable {
    /// The user has not been asked yet (no prompt was triggered to learn this).
    case notDetermined
    /// Granted — the dependent features are available.
    case granted
    /// Explicitly denied by the user.
    case denied
    /// Blocked by a system policy (MDM / Screen Time / parental controls); the user
    /// generally cannot flip it themselves.
    case restricted

    /// Whether the dependent features may run. Only an explicit grant counts, so
    /// everything else fails safe to "disabled" (a denied permission never leaves a
    /// feature half-working — User Story 25).
    public var isUsable: Bool { self == .granted }
}
